import Foundation

/// Pairs saved window records with live windows (SPEC section 12).
///
/// Bundle identifier alone does not identify a window — Chrome and Terminal
/// both routinely have several, and Chrome reorders its window list by focus,
/// so the index saved is not the index seen at restore time.
///
/// Titles are weighted highest because they are the most stable identifier
/// across a dock cycle. Geometry is weighted lowest because it is precisely the
/// thing that has just been disturbed.
///
/// The scoring and assignment are pure functions over `Candidate`, so they can
/// be tested without a live window server — see `SelfTest.runMatcherTests`.
enum WindowMatcher {

    enum Points {
        static let exactTitle: Double = 1000
        static let fuzzyTitle: Double = 600
        static let sameIndex: Double = 200
        static let sizeCloseness: Double = 100
        static let positionCloseness: Double = 50
    }

    /// A pair must clear this to be assigned by score. Anything below falls
    /// through to index-order pairing, which is still deterministic.
    static let minimumScore: Double = 150

    /// A live window reduced to the four things matching looks at. AX reads are
    /// expensive and scoring is O(saved x live), so these are read once.
    struct Candidate {
        let bundleID: String
        let title: String
        let index: Int
        let frame: Rect?
        let key: String
    }

    struct Assignment {
        /// (index into `saved`, index into `candidates`, score, reason)
        var pairs: [(saved: Int, candidate: Int, score: Double, reason: String)] = []
        var unmatchedSaved: [Int] = []
        var untouchedCandidates: [Int] = []
    }

    struct Pair {
        let saved: SavedWindow
        let live: AXWindow
        let score: Double
        let reason: String
    }

    struct Result {
        var pairs: [Pair] = []
        /// Saved entries with no live window: the app quit, or has fewer
        /// windows open than when the layout was captured.
        var unmatchedSaved: [SavedWindow] = []
        /// Live windows with no saved entry. Never touched.
        var untouchedLive: [AXWindow] = []
    }

    // MARK: - Live entry point

    static func pair(saved: [SavedWindow], live: [AXWindow]) -> Result {
        let candidates = live.map {
            Candidate(bundleID: $0.bundleIdentifier, title: $0.title,
                      index: $0.index, frame: $0.frame, key: "\($0.pid)#\($0.index)")
        }
        let assignment = assign(saved: saved, candidates: candidates)

        var result = Result()
        result.pairs = assignment.pairs.map {
            Pair(saved: saved[$0.saved], live: live[$0.candidate],
                 score: $0.score, reason: $0.reason)
        }
        result.unmatchedSaved = assignment.unmatchedSaved.map { saved[$0] }
        result.untouchedLive = assignment.untouchedCandidates.map { live[$0] }
        return result
    }

    // MARK: - Pure assignment

    static func assign(saved: [SavedWindow], candidates: [Candidate]) -> Assignment {
        var assignment = Assignment()

        let savedByBundle = Dictionary(grouping: saved.indices, by: { saved[$0].bundleIdentifier })
        let liveByBundle = Dictionary(grouping: candidates.indices, by: { candidates[$0].bundleID })
        var assignedCandidates = Set<Int>()

        for (bundleID, savedIndices) in savedByBundle.sorted(by: { $0.key < $1.key }) {
            let liveIndices = liveByBundle[bundleID] ?? []
            guard !liveIndices.isEmpty else {
                assignment.unmatchedSaved.append(contentsOf: savedIndices)
                continue
            }

            var scored: [(saved: Int, candidate: Int, score: Double, reason: String)] = []
            for s in savedIndices {
                for c in liveIndices {
                    let (score, reason) = self.score(saved[s], candidates[c])
                    scored.append((s, c, score, reason))
                }
            }
            // Deterministic order for equal scores, so a tie never depends on
            // dictionary iteration order.
            scored.sort {
                $0.score != $1.score ? $0.score > $1.score
                    : ($0.saved != $1.saved ? $0.saved < $1.saved : $0.candidate < $1.candidate)
            }

            var takenSaved = Set<Int>()
            var takenLive = Set<Int>()
            for entry in scored where entry.score >= minimumScore {
                guard !takenSaved.contains(entry.saved),
                      !takenLive.contains(entry.candidate) else { continue }
                takenSaved.insert(entry.saved)
                takenLive.insert(entry.candidate)
                assignedCandidates.insert(entry.candidate)
                assignment.pairs.append(entry)
            }

            // Saved entries left unassigned fall back to saved index order
            // against whatever live windows remain.
            let leftoverSaved = savedIndices.filter { !takenSaved.contains($0) }
                .sorted { saved[$0].windowIndex < saved[$1].windowIndex }
            let leftoverLive = liveIndices.filter { !takenLive.contains($0) }
                .sorted { candidates[$0].index < candidates[$1].index }

            for (offset, s) in leftoverSaved.enumerated() {
                if offset < leftoverLive.count {
                    let c = leftoverLive[offset]
                    assignedCandidates.insert(c)
                    assignment.pairs.append((s, c, 0, "index-order fallback"))
                } else {
                    assignment.unmatchedSaved.append(s)
                }
            }
        }

        assignment.untouchedCandidates = candidates.indices.filter { !assignedCandidates.contains($0) }
        return assignment
    }

    static func score(_ saved: SavedWindow, _ candidate: Candidate) -> (Double, String) {
        var total: Double = 0
        var reasons: [String] = []

        if !saved.title.isEmpty, saved.title == candidate.title {
            total += Points.exactTitle
            reasons.append("exact title")
        } else {
            let similarity = titleSimilarity(saved.title, candidate.title)
            if similarity > 0 {
                total += Points.fuzzyTitle * similarity
                reasons.append(String(format: "title %.0f%%", similarity * 100))
            }
        }

        if saved.windowIndex == candidate.index {
            total += Points.sameIndex
            reasons.append("same index")
        }

        if let frame = candidate.frame {
            let savedFrame = saved.frame
            let sizeSpread = savedFrame.width + savedFrame.height
            let sizeDelta = abs(savedFrame.width - frame.width) + abs(savedFrame.height - frame.height)
            let sizeCloseness = sizeSpread > 0 ? max(0, 1 - sizeDelta / sizeSpread) : 0

            let positionSpread = max(savedFrame.width, 1) + max(savedFrame.height, 1)
            let positionDelta = abs(savedFrame.x - frame.x) + abs(savedFrame.y - frame.y)
            let positionCloseness = max(0, 1 - positionDelta / positionSpread)

            let geometry = Points.sizeCloseness * sizeCloseness
                         + Points.positionCloseness * positionCloseness
            total += geometry
            reasons.append(String(format: "geometry %.0f", geometry))
        }

        return (total, reasons.joined(separator: ", "))
    }

    /// Sørensen–Dice over character bigrams: cheap, order-aware enough for
    /// window titles, and stable when only part of a title changes — the common
    /// case, where "… — Google Chrome" survives a page change.
    ///
    /// 2 x shared / total, over multisets, so a repeated bigram matches only as
    /// often as it actually occurs in both.
    static func titleSimilarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }

        let first = bigrams(a.lowercased())
        let second = bigrams(b.lowercased())
        guard !first.isEmpty, !second.isEmpty else { return 0 }

        var remaining: [String: Int] = [:]
        for gram in second { remaining[gram, default: 0] += 1 }

        var shared = 0
        for gram in first where (remaining[gram] ?? 0) > 0 {
            remaining[gram]! -= 1
            shared += 1
        }

        return 2.0 * Double(shared) / Double(first.count + second.count)
    }

    private static func bigrams(_ string: String) -> [String] {
        let characters = Array(string)
        guard characters.count > 1 else { return characters.map(String.init) }
        return (0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) }
    }
}
