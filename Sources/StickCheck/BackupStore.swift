import Foundation
import StickCore

/// Saves configuration blocks read from a stick. The files hold per-unit calibration, so they
/// live in Application Support, not in a project folder.
enum BackupStore {
    enum Failure: Error, CustomStringConvertible {
        case readBackMismatch

        var description: String { "The saved file does not match what was read from the stick." }
    }

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stick Check/Backups", isDirectory: true)
    }

    /// Writes the raw block, reads it back to be sure, and write-protects it.
    static func save(_ block: VKBBlock, deviceName: String, date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let url = folder.appendingPathComponent("\(deviceName) \(formatter.string(from: date)).vkbblock")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = Data(block.bytes)
        try data.write(to: url, options: .withoutOverwriting)
        guard try Data(contentsOf: url) == data else { throw Failure.readBackMismatch }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        return url
    }
}
