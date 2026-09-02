#!/bin/zsh
# Health check for Desk Restore. Run this after any macOS update, after a
# Command Line Tools update, or any time it starts behaving oddly.
#
#   ./verify.sh          checks that move no windows
#   ./verify.sh --full   also runs the 10-cycle drift test (scatters your windows)
#
# Exits non-zero if any check fails, so it can be wired into a cron job later.
set -uo pipefail

APP="/Applications/Desk Restore.app"
SUPPORT="$HOME/Library/Application Support/DeskRestore"
LOG="$SUPPORT/debug.log"
BASELINE="$SUPPORT/signing-baseline.txt"
FULL=0
[[ "${1:-}" == "--full" ]] && FULL=1

FAILS=0
pass() { printf "  \033[32mok\033[0m    %s\n" "$1" }
fail() { printf "  \033[31mFAIL\033[0m  %s\n" "$1"; FAILS=$((FAILS+1)) }
info() { printf "        %s\n" "$1" }

echo "Desk Restore health check — $(date '+%Y-%m-%d %H:%M')"
echo "macOS $(sw_vers -productVersion)  ·  Swift $(swift --version 2>&1 | sed -n 's/.*Apple Swift version \([0-9.]*\).*/\1/p' | head -1)  ·  SDK $(xcrun --show-sdk-version 2>/dev/null)"
echo ""

# 1. Installed
if [[ -d "$APP" ]]; then pass "installed at $APP"
else fail "not installed at $APP — run ./build.sh"; echo; exit 1; fi

# 2. Signature stable. If this changed, the Accessibility grant is about to be lost.
# The designated requirement is what macOS ties the Accessibility grant to.
# It is machine-specific, so it is recorded on first run and compared after.
DR_REQ="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
if [[ ! -f "$BASELINE" ]]; then
  mkdir -p "$SUPPORT"; print -r -- "$DR_REQ" > "$BASELINE"
  pass "signing baseline recorded"
  info "$DR_REQ"
elif [[ "$DR_REQ" == "$(<"$BASELINE")" ]]; then
  pass "signing identity unchanged since the baseline"
else
  fail "signing identity changed — Accessibility will need re-granting"
  info "was: $(<"$BASELINE")"
  info "now: $DR_REQ"
  info "if this was intentional, delete $BASELINE and re-run"
fi
if [[ "$DR_REQ" == *"adhoc"* || -z "$DR_REQ" ]]; then
  fail "ad-hoc signed — the Accessibility grant will not survive rebuilds"
  info "see README section 'Signing'"
fi

# 3. Running
if pgrep -x "Desk Restore" >/dev/null; then pass "agent is running"
else
  info "agent not running; starting it"
  open -a "$APP"; sleep 4
  pgrep -x "Desk Restore" >/dev/null && pass "agent started" || fail "agent will not stay running"
fi

# 4. Turn on logging for the duration of the checks.
WAS_DEBUG="$(defaults read com.nico.desk-restore debugLogging 2>/dev/null || echo 0)"
defaults write com.nico.desk-restore debugLogging -bool true
pkill -x "Desk Restore" >/dev/null 2>&1; sleep 1; open -a "$APP"; sleep 4
: > "$LOG"

# 5. Accessibility + the coordinate model. If toCG(frame) stops matching
#    CGDisplayBounds, macOS changed something fundamental and every saved
#    frame is untrustworthy — that is the check that matters most here.
open "deskrestore://probe"; sleep 4
if grep -q "Accessibility not granted" "$LOG"; then
  fail "Accessibility not granted"
  info "System Settings > Privacy & Security > Accessibility > enable Desk Restore"
elif grep -q "coordinate check: toCG(frame) == CGDisplayBounds" "$LOG"; then
  pass "Accessibility granted"
  pass "coordinate model intact (toCG == CGDisplayBounds)"
elif grep -q "COORDINATE CHECK FAILED" "$LOG"; then
  fail "COORDINATE MODEL BROKEN — do not trust saved layouts"
  grep "COORDINATE CHECK FAILED" "$LOG" | sed 's/^/        /'
else
  fail "probe produced no coordinate result"
fi

WINDOWS="$(grep -oE 'eligible windows: [0-9]+' "$LOG" | grep -oE '[0-9]+' | head -1)"
[[ -n "$WINDOWS" && "$WINDOWS" -gt 0 ]] && pass "enumerated $WINDOWS eligible windows" \
                                        || fail "enumerated no windows — AX access may be broken"

# 6. Matcher logic. Pure, moves nothing.
: > "$LOG"
open "deskrestore://selftest-matcher"; sleep 4
if grep -q "SELFTEST MATCHER PASS" "$LOG"; then pass "matcher self-tests (9 cases)"
else
  fail "matcher self-tests"
  grep "FAIL " "$LOG" | sed 's/^.*FAIL/        FAIL/'
fi

# 7. Saved layout still readable under the current schema.
if [[ -f "$SUPPORT/layouts.json" ]]; then
  V="$(python3 -c "import json;d=json.load(open('$SUPPORT/layouts.json'));print(d['version'],len(d['layouts'][0]['windows']))" 2>/dev/null)"
  [[ -n "$V" ]] && pass "layouts.json readable (schema v${V% *}, ${V#* } windows)" \
                || fail "layouts.json unreadable or malformed"
else
  info "no layout saved yet — nothing to check"
fi

# 8. Drift, opt-in because it throws your windows around.
if [[ $FULL -eq 1 ]]; then
  echo ""
  info "running the 10-cycle drift test — your windows will move for about a minute"
  : > "$LOG"
  open "deskrestore://selftest?cycles=10"; sleep 75
  if grep -q "SELFTEST PASS" "$LOG"; then pass "no drift across 10 restore cycles"
  else
    fail "drift detected across restore cycles"
    grep -A6 "SELFTEST FAIL" "$LOG" | sed 's/^/        /'
  fi
else
  info "skipping the drift test — re-run with --full to include it"
fi

# 9. Put the logging setting back.
[[ "$WAS_DEBUG" == "1" ]] || defaults write com.nico.desk-restore debugLogging -bool false

echo ""
if [[ $FAILS -eq 0 ]]; then
  echo "All checks passed."
else
  echo "$FAILS check(s) failed. Full log: $LOG"
fi
exit $FAILS
