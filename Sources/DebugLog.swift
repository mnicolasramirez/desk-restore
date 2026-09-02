import Foundation

/// Append-only diagnostic log.
///
/// Records geometry, bundle identifiers, window titles and AX error codes.
/// Never window content, never pixels — see SPEC section 15.
final class DebugLog: @unchecked Sendable {

    static let shared = DebugLog()

    /// `~/Library/Application Support/DeskRestore/`. The only directory this
    /// app ever writes to.
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("DeskRestore", isDirectory: true)
    }

    private let url: URL
    private let queue = DispatchQueue(label: "com.nico.desk-restore.log")
    private let formatter: DateFormatter

    /// Set from settings. Errors and pass summaries are logged regardless;
    /// only per-window detail is gated, so a bug report never needs the flag
    /// to have been on in advance.
    var isEnabled: Bool = false

    private init() {
        url = DebugLog.supportDirectory.appendingPathComponent("debug.log")
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        try? FileManager.default.createDirectory(at: DebugLog.supportDirectory,
                                                 withIntermediateDirectories: true)
    }

    /// Detail line — written only when debug logging is on.
    func debug(_ message: String) {
        guard isEnabled else { return }
        write("     " + message)
    }

    /// Always written. Pass boundaries, errors, permission and mode changes.
    func note(_ message: String) {
        write("     " + message)
    }

    /// Always written, and visually separated. One per save/restore pass.
    func heading(_ message: String) {
        write("\n=== " + message + " ===")
    }

    /// Synchronous on purpose. An async write is lost when the process calls
    /// `exit()`, which silently truncates exactly the lines you need when
    /// diagnosing why a pass ended early. Volume here is a few hundred lines
    /// per pass, so serialising costs nothing that matters.
    private func write(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        queue.sync { [url] in
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Trim the log if it grows past a megabyte. A debug log that fills a disk
    /// is a worse bug than the one it was left on to catch.
    func rotateIfNeeded() {
        queue.sync { [url] in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int, size > 1_000_000 else { return }
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
            let lines = contents.components(separatedBy: "\n")
            let kept = lines.suffix(2000).joined(separator: "\n")
            try? kept.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
