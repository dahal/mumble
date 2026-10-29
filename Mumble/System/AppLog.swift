import AppKit
import os

/// A small persistent log at ~/Library/Logs/Mumble/Mumble.log (also mirrored to the unified log),
/// so failures in the field can be diagnosed without Xcode. Never logs transcript text.
enum AppLog {
    static let fileURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appending(path: "Logs/Mumble/Mumble.log")

    private static let logger = Logger(subsystem: "dev.mumble.Mumble", category: "app")
    private static let queue = DispatchQueue(label: "dev.mumble.log")
    private static let maxBytes = 1_000_000

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        logger.notice("\(message, privacy: .public)")
        let line = "\(Date().formatted(.iso8601)) [\(level)] \(message)\n"
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maxBytes {
                try? fm.removeItem(at: fileURL.appendingPathExtension("1"))
                try? fm.moveItem(at: fileURL, to: fileURL.appendingPathExtension("1"))
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: fileURL)
            }
        }
    }

    @MainActor static func reveal() {
        if !FileManager.default.fileExists(atPath: fileURL.path) { info("Log opened") }
        queue.sync {}
        NSWorkspace.shared.open(fileURL)
    }
}
