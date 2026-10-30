import Foundation
import MumbleCore

/// Writes the optional plain-file copy of a meeting's notes (spec §12.6). One-way: the database is
/// the source of truth. Never includes private notes or voice data, and never overwrites a file it
/// didn't write.
public enum MarkdownCopy {
    /// Writes (or rewrites) the meeting's Markdown file in `folder` and returns its path.
    ///
    /// - Parameter previousPath: the path written last time. It is reused only if a file still
    ///   exists there (the user may have moved or renamed it; then a new file is written instead).
    public static func write(_ doc: MeetingDocument, to folder: URL, previousPath: String?) throws -> String {
        let markdown = MarkdownExporter.render(doc, includePrivateNotes: false)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let previousPath, FileManager.default.fileExists(atPath: previousPath),
           URL(fileURLWithPath: previousPath).deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            try markdown.write(toFile: previousPath, atomically: true, encoding: .utf8)
            return previousPath
        }
        let url = availableURL(in: folder, fileName: MarkdownExporter.fileName(for: doc.meeting))
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// `name.md`, or `name (2).md`, `name (3).md`… when taken.
    static func availableURL(in folder: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        var url = folder.appending(path: fileName)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) (\(n)).md")
            n += 1
        }
        return url
    }
}
