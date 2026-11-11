import CryptoKit
import Foundation
import StickCore
import StickHID

/// Command-line access to a VKB stick's stored configuration. Read-only: it asks the stick for its
/// configuration block and never sends a write or a command.
@MainActor
enum VKBCommand {
    static var backupFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stick Check/Backups", isDirectory: true)
    }

    /// Prints the configuration summary; with `backup`, also saves the block. Returns the exit code.
    static func run(backup: Bool) -> Int32 {
        let source = HIDStickSource()
        source.start()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        if let error = source.openError { print(error); return 1 }
        guard let id = source.devices.first(where: { $0.vendorID == 0x231D })?.id else {
            print("No VKB stick found.")
            return 1
        }
        source.select(id)
        guard let device = source.selectedDeviceInfo, let transport = source.vkbTransport() else {
            print("Could not open the stick.")
            return 1
        }
        print("\(device.name) — \(device.idText)")

        do {
            var link = VKBLink(transport: transport)
            let token = try link.readToken()
            let block = try link.readBlock(token: token)
            print("Session token: read (\(token.count) bytes, not shown: it is the stick's serial number)")
            print(block.summary)
            guard block.isIntact else {
                print("The checksum does not match, so this is not a trustworthy copy. Nothing was saved.")
                return 2
            }
            // Flash and RAM copies should agree; a difference would mean unsaved changes on the stick.
            let ram = try link.readBlock(token: token, from: .readRAM)
            print(ram == block ? "RAM copy: identical to flash" : "RAM copy: DIFFERS from flash")
            print("Requests repeated after a stale reply: \(link.retries)")
            if backup { try save(block, device: device) }
            return 0
        } catch {
            print("Failed: \(error)")
            return 1
        }
    }

    private static func save(_ block: VKBBlock, device: DeviceInfo) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let name = "\(device.name) \(formatter.string(from: Date())).vkbblock"
        let url = backupFolder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let data = Data(block.bytes)
        try data.write(to: url, options: .withoutOverwriting)
        // Read it back: a backup that was not checked is not a backup.
        guard try Data(contentsOf: url) == data else {
            print("The saved file does not match what was read. Do not rely on it.")
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        print("Backup saved and read back: \(url.path)")
        print("SHA-256: \(digest)")
    }
}
