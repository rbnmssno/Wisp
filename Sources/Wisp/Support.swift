import AppKit
import os

/// Development output and a few lines in the system log
/// (`/usr/bin/log show --predicate 'subsystem == "app.wisp.Wisp"' --last 10m --style compact`).
enum Log {
    private static let logger = Logger(subsystem: "app.wisp.Wisp", category: "app")
    static var echo = false

    static func debug(_ message: @autoclosure () -> String) {
        guard echo else { return }
        FileHandle.standardError.write(Data((message() + "\n").utf8))
    }

    static func note(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        debug(message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        debug("error: " + message)
    }
}

/// A cancellable one-shot timer on the main queue.
final class OneShot {
    private var item: DispatchWorkItem?

    var isPending: Bool { item != nil }

    func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        item?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.item = nil
            block()
        }
        item = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay), execute: work)
    }

    func cancel() {
        item?.cancel()
        item = nil
    }

    deinit { item?.cancel() }
}

extension Comparable {
    func clamped(_ low: Self, _ high: Self) -> Self { min(max(self, low), high) }
}

/// Command-line switches for development.
enum Args {
    static func has(_ flag: String) -> Bool { CommandLine.arguments.contains(flag) }

    static func value(_ flag: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    /// `--isolated`: a test copy that runs beside the real Wisp and touches nothing of it.
    static var isolated: Bool { has("--isolated") }
}

/// Where settings live. A test copy (`--isolated`) keeps its own, so it never changes the real ones.
enum Store {
    static let defaults: UserDefaults = Args.isolated
        ? (UserDefaults(suiteName: (Bundle.main.bundleIdentifier ?? "app") + ".test") ?? .standard)
        : .standard
}
