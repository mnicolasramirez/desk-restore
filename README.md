# Desk Restore

A tiny macOS menu-bar agent that remembers where your windows belong on your desk
monitor, and puts them back when you dock.

## The problem

Two configurations, one of which macOS handles badly.

**Laptop.** Built-in display only. macOS is fine here. Desk Restore does nothing at
all in this mode — deliberately.

**Desktop.** MacBook connected to one large external monitor, lid closed. When the
external monitor comes back, macOS carries the small laptop-sized window geometry
over to the large display, and every window has to be resized and repositioned by
hand.

Desk Restore captures the arrangement once and replays it.

## What it is not

Not a window manager. No snapping, no tiling, no grids, no workspace or Space
management. It does not launch applications, and it positions browser *windows*,
never tabs. Those are explicit non-goals — if you want a window manager, there are
several good ones.

## Install

Requires macOS 14 or later and the Command Line Tools (`xcode-select --install`).
Xcode is not needed.

```bash
git clone https://github.com/mnicolasramirez/desk-restore.git
cd desk-restore
./build.sh
```

That compiles, assembles the bundle, signs it, and installs to `/Applications`.
Launch it, then grant Accessibility when asked.

Check it over any time — after a macOS update, say:

```bash
./verify.sh
```

## Use

Click the menu bar icon:

- **Save Current Desktop Layout** — capture where everything is now
- **Restore Desktop Layout** — put everything back
- **Automatic Restore** — restore when the desk monitor reconnects (on by default)

Global shortcut **⌃⌥⌘R** restores. Both are also reachable over a URL scheme, so
Shortcuts, Raycast and Keyboard Maestro can drive it:

```bash
open "deskrestore://restore"
```

| URL | Effect |
|---|---|
| `deskrestore://save` | save the current layout |
| `deskrestore://restore` | restore the saved layout |
| `deskrestore://probe` | dump displays, windows and skips to the log |
| `deskrestore://selftest-matcher` | matcher unit tests; moves nothing |
| `deskrestore://selftest?cycles=10` | drift test; scatters your windows |
| `deskrestore://quit` | quit the agent |

## Privacy

**Accessibility is the only permission requested.** It is what allows one app to
move another app's windows.

**Screen Recording is never requested.** Desk Restore reads window *metadata* —
position, size, title, role — never pixels and never content.

There is no network code of any kind. No analytics, no telemetry, no accounts, no
update checks. The only files written are `layouts.json` and, if you turn on debug
logging, `debug.log`, both under `~/Library/Application Support/DeskRestore/`.

Roughly 16 MB of memory and about 0.03% CPU while idle — it sleeps until macOS
reports a display change.

## How it works

Three parts are worth explaining, because they are where this kind of tool usually
goes wrong.

### Coordinates

macOS has two coordinate systems. AppKit puts the origin at the **bottom**-left of
the primary display with y increasing upward. CoreGraphics and the Accessibility
API put it at the **top**-left with y increasing downward.

Desk Restore works entirely in CoreGraphics top-left **points** — points, not
pixels, because a scaled HiDPI display reports different numbers for each. AppKit
rectangles are converted exactly once, on the way in, by a transform that is its own
inverse. Debug builds assert that `toCG(screen.frame) == CGDisplayBounds(displayID)`;
if that ever disagrees, every frame downstream is garbage and the app says so.

`visibleFrame` rather than `frame` is the reference rectangle throughout, so the menu
bar and the Dock are accounted for automatically — including a Dock that later
changes size or hiding behaviour.

### No drift

Each window is stored three ways: the absolute frame, an offset from its display's
`visibleFrame` origin, and fractions of that `visibleFrame`.

Restore uses the display-local offset when the target display's usable area and
backing scale both match what was saved, and denormalises the fractions otherwise.
Display-local rather than absolute is what survives arrangement changes: global
origins shift whenever the built-in display appears or disappears, so an absolute
frame saved in clamshell can land off-screen once the lid is open.

Crucially, restore recomputes from the *saved* record against the *current* display
and never reads the window's present position. Reading current geometry and adjusting
it is the classic drift bug — the one where windows creep a few pixels every cycle.
Identical inputs produce identical output, so ten dock cycles produce ten identical
frames. There is a test for exactly this.

### Matching windows

A bundle identifier does not identify a window — Chrome routinely has several, and
reorders its window list by focus, so the index you saved is often not the index you
find later.

Saved entries are grouped by application and every saved-to-live pair is scored:
exact title 1000, fuzzy title similarity up to 600 (Sørensen–Dice over character
bigrams), same index 200, geometry closeness up to 150. Pairs are assigned greedily,
one-to-one, in descending score order.

Titles dominate because they are the most stable identifier across a dock cycle.
Geometry is weighted lowest because it is precisely the thing that has just been
disturbed.

## Which windows are managed

A window is moved only if its application is a regular, visible app, and the window
is a standard window (`AXStandardWindow` — this one check drops dialogs, sheets and
floating palettes without a hand-kept blocklist), is not minimized, reports both
position and size as settable, is not in native full screen, and is at least
200 × 100 points.

Everything else is skipped and the reason is logged. One failure never aborts a pass.

## Applying a frame

Position first, then size, then correct the origin that the resize moved.

macOS clamps a resize against the display the window currently occupies, so moving a
small laptop-sized window onto a large monitor and resizing in one step silently
truncates the resize — at the moment of the resize the window still belongs to the
old display. The sequence retries up to three times, 250 ms apart.

Tolerance is ±2 points. Some applications legitimately quantise their geometry —
Terminal snaps to character cells, and WhatsApp refuses to go below 800 × 600 — so a
window that lands close but not exact is recorded as `constrained`, with both the
requested and achieved frames logged. That is reported separately from `failed`,
because it is not an error.

## Automatic restore

Driven by `didChangeScreenParametersNotification`, which also fires on clamshell
transitions. Two independent guards stop a noisy dock from producing a burst of
restores: a debounce collapses the several notifications macOS emits mid-transition,
and a two-sample display fingerprint refuses to act until the configuration has
stopped moving. It triggers on the laptop→desktop **edge**, not the desktop
**state**, which is what guarantees one restore per docking sequence.

## Signing

macOS ties the Accessibility grant to the code signature, and an ad-hoc signature
changes on every build — which would mean re-approving the app after every rebuild.

A self-signed certificate fixes it, because the designated requirement then stays
constant even as the code hash changes. Create one once:

```bash
mkdir -p ~/desk-restore-build/signing && cd ~/desk-restore-build/signing && openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -keyout dr-key.pem -out dr-cert.pem -subj "/CN=Desk Restore Dev" -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
```

```bash
cd ~/desk-restore-build/signing && openssl pkcs12 -export -out dr.p12 -inkey dr-key.pem -in dr-cert.pem -name "Desk Restore Dev" -passout pass:deskrestore
```

```bash
cd ~/desk-restore-build/signing && security import dr.p12 -k "$HOME/Library/Keychains/login.keychain-db" -f pkcs12 -P "deskrestore" -T /usr/bin/codesign -T /usr/bin/security
```

Then rebuild and grant Accessibility once. `build.sh` warns and falls back to ad-hoc
signing if the certificate is missing. Note that `security find-identity -p
codesigning` reports zero identities even when this works — that filter only counts
certificates carrying explicit trust settings, which `codesign` does not require.

Installing Xcode and signing with a free Apple ID team achieves the same thing.

## Known limitations

- **Native full-screen windows are skipped.** They live in their own Space and cannot
  be repositioned through the Accessibility API. Detected and logged, never fought.
- **Other Spaces.** Windows on a Space other than the current one may not be
  enumerable or movable, and are skipped.
- **Applications that resist resizing** land as close as they allow and are reported
  as `constrained`.
- **Moving the app** invalidates the Accessibility grant, which is tied to the path as
  well as the signature. Install once, then leave it.
- **Multi-monitor is unexercised.** The data model supports several displays per
  layout and the code paths exist, but this has only ever been run against a single
  external display.
- **The Xcode project is unverified.** `DeskRestore.xcodeproj` is hand-written and its
  structure validates, but it has never been opened in Xcode. `build.sh` is the
  tested path.

## Tests

```bash
./verify.sh          # signature, permission, coordinate model, matcher tests
./verify.sh --full   # adds the 10-cycle drift test
```

Nine matcher unit tests cover the awkward cases: titles outranking indices when they
disagree, titles that changed since the save, fewer live windows than saved, extra
live windows left untouched, and an application that quit. The drift test saves a
layout, then scatters and restores ten times with different random starting
arrangements, and requires all ten results to be identical.

## Built with

Swift and SwiftUI, no third-party dependencies. Accessibility API for window
geometry, CoreGraphics for display identity, Carbon `RegisterEventHotKey` for the
global shortcut (still the only supported way to get one without an event tap, which
would be a much heavier permission), and `SMAppService` for launch at login.

App Sandbox is off and must stay off — a sandboxed process cannot drive other
applications through the Accessibility API. That also means this can never ship on
the Mac App Store, which is fine.

## Licence

MIT — see [LICENSE](LICENSE).
