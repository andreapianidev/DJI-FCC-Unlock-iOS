import Foundation
import OSLog

/// Mirrors the in-app log to two places that survive the app being closed:
/// the unified log, which shows up live in Xcode's console, and a plain text
/// file in the app container, which can be pulled off the device afterwards
/// with `devicectl device copy from` or opened in the Files app.
///
/// The in-app Log tab keeps only the last 200 lines and dies with the process.
/// A test run on real hardware is worth more than that.
final class DiagnosticLog: @unchecked Sendable {

    static let shared = DiagnosticLog()

    /// Subsystem to filter on when streaming: `log stream --predicate
    /// 'subsystem == "com.andreapiani.freefcc"'`.
    static let subsystem = "com.andreapiani.freefcc"

    private let logger = Logger(subsystem: DiagnosticLog.subsystem, category: "session")
    private let queue = DispatchQueue(label: "com.andreapiani.freefcc.diaglog")
    private var handle: FileHandle?

    /// Where the session log lands inside the app container.
    static var fileURL: URL? {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("freefcc-session.log")
    }

    private init() {}

    /// Writes the run header. Called once at startup so every pulled file says
    /// which build and which device produced it.
    func startSession(header: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            let banner = (["", String(repeating: "=", count: 60)] + header + [String(repeating: "=", count: 60)])
                .joined(separator: "\n")
            self.write(banner)
        }
        for line in header {
            logger.notice("\(line, privacy: .public)")
        }
    }

    /// Mirrors one already-timestamped log line.
    func append(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        queue.async { [weak self] in self?.write(line) }
    }

    /// Runs on the private queue only.
    private func write(_ line: String) {
        guard let url = Self.fileURL else { return }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            try? handle?.seekToEnd()
        }
        guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }
}
