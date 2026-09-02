import Foundation

/// One window as captured, in all three stored forms (SPEC section 7).
///
/// `absolute` alone would not survive an arrangement change — global origins
/// shift whenever the built-in display appears or disappears, so a frame saved
/// in clamshell can land off-screen once the lid is open. `displayLocalFrame`
/// cannot. `absolute` is kept for the debug log and for diagnosing drift.
struct SavedWindow: Codable, Equatable {
    var bundleIdentifier: String
    var applicationName: String
    var title: String
    var windowIndex: Int
    var subrole: String
    var displayIdentity: DisplayIdentity

    /// Absolute frame as captured, in global CG points.
    var frame: Rect
    /// Offset from the owning display's visibleFrame origin.
    var displayLocalFrame: Rect
    /// Fractions of the owning display's visibleFrame.
    var normalized: NormalizedFrame

    /// Derive all three forms from an absolute frame and its display.
    init(bundleIdentifier: String, applicationName: String, title: String,
         windowIndex: Int, subrole: String, absoluteFrame w: Rect,
         display: DisplaySnapshot) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.title = title
        self.windowIndex = windowIndex
        self.subrole = subrole
        self.displayIdentity = display.identity
        self.frame = w

        let v = display.visibleFrame
        self.displayLocalFrame = Rect(x: w.minX - v.minX, y: w.minY - v.minY,
                                      width: w.width, height: w.height)
        self.normalized = NormalizedFrame(
            normalizedX: v.width  > 0 ? (w.minX - v.minX) / v.width  : 0,
            normalizedY: v.height > 0 ? (w.minY - v.minY) / v.height : 0,
            normalizedWidth:  v.width  > 0 ? w.width  / v.width  : 1,
            normalizedHeight: v.height > 0 ? w.height / v.height : 1)
    }
}

/// A complete arrangement: the displays it was captured on, and the windows.
struct Layout: Codable, Equatable {
    var id: String
    var name: String
    var savedAt: Date
    var displays: [DisplaySnapshot]
    var windows: [SavedWindow]

    /// The saved snapshot a window was captured on, needed at restore time to
    /// decide between the pixel-exact and the proportional path.
    func savedDisplay(for identity: DisplayIdentity) -> DisplaySnapshot? {
        displays.first { $0.identity == identity }
    }

    var targetIdentities: [DisplayIdentity] { displays.map(\.identity) }
}

/// Versioned envelope. V1 only ever writes one layout, with id `desktop`, but
/// the array costs nothing now and makes a second layout a data change rather
/// than a migration.
struct LayoutFile: Codable, Equatable {
    var version: Int
    var layouts: [Layout]

    static let currentVersion = 1
    static let empty = LayoutFile(version: LayoutFile.currentVersion, layouts: [])

    func layout(id: String) -> Layout? { layouts.first { $0.id == id } }

    mutating func upsert(_ layout: Layout) {
        if let index = layouts.firstIndex(where: { $0.id == layout.id }) {
            layouts[index] = layout
        } else {
            layouts.append(layout)
        }
    }
}

/// Codable JSON persistence with atomic writes. Knows nothing about AX or
/// displays.
enum LayoutStore {

    static let defaultLayoutID = "desktop"

    static var url: URL {
        DebugLog.supportDirectory.appendingPathComponent("layouts.json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Modification date, for cheap staleness checks. A `stat` costs a
    /// fraction of a JSON decode, which matters when the alternative is
    /// decoding on a timer for the life of the process.
    static var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Missing file is not an error — it is the first-run state.
    static func load() throws -> LayoutFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return .empty }
        let data = try Data(contentsOf: url)
        return try decoder.decode(LayoutFile.self, from: data)
    }

    /// Temp file plus rename, so an interrupted write cannot corrupt a good
    /// layout (SPEC section 13).
    static func save(_ file: LayoutFile) throws {
        try FileManager.default.createDirectory(at: DebugLog.supportDirectory,
                                                withIntermediateDirectories: true)
        let data = try encoder.encode(file)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("layouts.json.tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }
}
