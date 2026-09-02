import Foundation

/// How this process was launched.
///
/// The agent is the resident mode: menu bar, hotkey, automatic restore. The
/// one-shot modes exist for a docking cadence measured in weeks rather than
/// hours — where keeping a process resident to catch two events a month is a
/// poor trade. A one-shot launch shows no menu bar item, does exactly one
/// thing, and exits.
enum LaunchMode: String {
    case agent
    case restoreAndQuit
    case saveAndQuit

    /// Read once: the arguments cannot change while the process lives.
    static let current: LaunchMode = {
        let arguments = CommandLine.arguments
        if arguments.contains("--restore-and-quit") { return .restoreAndQuit }
        if arguments.contains("--save-and-quit") { return .saveAndQuit }
        return .agent
    }()

    var isOneShot: Bool { self != .agent }
}
