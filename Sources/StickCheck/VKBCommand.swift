import CryptoKit
import Foundation
import StickCore
import StickHID

/// Command-line access to a VKB stick's stored configuration. `run` only reads. `restore` writes
/// a saved configuration back, and only when given `--yes`.
@MainActor
enum VKBCommand {
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
            if backup {
                let url = try BackupStore.save(block, deviceName: device.name)
                let digest = SHA256.hash(data: Data(block.bytes)).map { String(format: "%02x", $0) }.joined()
                print("Backup saved and read back: \(url.path)")
                print("SHA-256: \(digest)")
            }
            return 0
        } catch {
            print("Failed: \(error)")
            return 1
        }
    }

    /// Finds the VKB stick and waits briefly for it to be matched.
    private static func connect(_ source: HIDStickSource) -> (device: DeviceInfo, transport: HIDFeatureTransport)? {
        guard let id = source.devices.first(where: { $0.vendorID == 0x231D })?.id else { return nil }
        source.select(id)
        guard let device = source.selectedDeviceInfo, let transport = source.vkbTransport() else { return nil }
        return (device, transport)
    }

    /// Writes a saved configuration block back to the stick. Without `confirmed` it is a dry run:
    /// every check is made and the differences are listed, but nothing is sent.
    static func restore(path: String, confirmed: Bool) -> Int32 {
        let source = HIDStickSource()
        source.start()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        if let error = source.openError { print(error); return 1 }
        guard let (device, transport) = connect(source) else {
            print("No VKB stick found.")
            return 1
        }
        print("\(device.name) — \(device.idText)")

        do {
            let block = try VKBBlock(bytes: [UInt8](try Data(contentsOf: URL(fileURLWithPath: path))))
            var link = VKBLink(transport: transport)
            let token = try link.readToken()
            let current = try link.readBlock(token: token)
            guard current.isIntact else {
                print("The stick's own checksum does not match what was read. Stopping.")
                return 2
            }
            print("On the stick:  type id 0x\(String(format: "%02X", current.typeID)), firmware \(current.firmwareText), checksum \(String(format: "%08X", current.storedCRC))")
            print("In the file:   type id 0x\(String(format: "%02X", block.typeID)), firmware \(block.firmwareText), checksum \(String(format: "%08X", block.storedCRC)) — \(block.isIntact ? "intact" : "DAMAGED")")
            guard block.isIntact else { print("The file fails its own checksum. Nothing was sent."); return 2 }
            guard block.typeID == current.typeID, block.firmware == current.firmware else {
                print("The file is for a different device type or firmware. Nothing was sent.")
                return 2
            }
            let differences = block.differences(from: current)
            if differences.isEmpty {
                print("The file is byte-identical to what the stick holds.")
            } else {
                let places = differences.prefix(12).map { String(format: "0x%03X", $0) }.joined(separator: " ")
                print("The file differs from the stick in \(differences.count) bytes: \(places)\(differences.count > 12 ? " …" : "")")
            }
            guard confirmed else {
                print("Dry run: nothing was sent. Add --yes to write the file to the stick; the stick then restarts.")
                return 0
            }

            let status = try link.writeBlock(block, token: token, replacing: current)
            print("Stick answered: \(status)")
            guard status == .written else { return 3 }

            // The stick leaves the bus and comes back a few seconds later as a new device.
            print("Waiting for the stick to restart…")
            let deadline = Date().addingTimeInterval(15)
            var back: (device: DeviceInfo, transport: HIDFeatureTransport)?
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                if let found = connect(source), found.device.id != device.id {
                    back = found
                    break
                }
            }
            guard let back else {
                print("The stick did not come back within 15 seconds. Unplug it and plug it in again, then run --vkb-info.")
                return 4
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            var after = VKBLink(transport: back.transport)
            let stored = try after.readBlock(token: try after.readToken())
            if stored == block {
                print("Verified after the restart: the stick holds exactly the file's contents.")
                return 0
            }
            print("AFTER THE RESTART THE STICK DIFFERS from the file in \(stored.differences(from: block).count) bytes. Checksum on the stick \(stored.isIntact ? "matches" : "does NOT match").")
            return 5
        } catch {
            print("Failed: \(error)")
            return 1
        }
    }

    // MARK: - Calibration (experimental)

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private static func calibrationLines(_ block: VKBBlock) -> [String] {
        block.logicalAxes.filter { $0.enabled && $0.visible && $0.physicalSlot < 8 }.map { axis in
            let sensor = block.physicalAxes[axis.physicalSlot]
            return String(format: "  %@ slot %d  Bias %+5d  KdLo %3d  KdHi %3d",
                          axis.usageName.padding(toLength: 4, withPad: " ", startingAt: 0),
                          sensor.slot, sensor.bias, sensor.kdLo, sensor.kdHi)
        }
    }

    /// Waits for the stick to come back as a new device after a restart. Nil if it never left.
    private static func waitForRestart(_ source: HIDStickSource, oldID: UInt64, seconds: Double) -> (device: DeviceInfo, transport: HIDFeatureTransport)? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            if let found = connect(source), found.device.id != oldID {
                RunLoop.main.run(until: Date().addingTimeInterval(1.0))
                return found
            }
        }
        return nil
    }

    /// Runs the stick's own calibration: start, you move every axis, commit. Each step waits for
    /// Return. The calibration commands are known only from the vendor tool's binary, so this
    /// saves a backup first and reports exactly what changed.
    static func calibrate(form: VKBShortCommandForm) -> Int32 {
        let source = HIDStickSource()
        source.start()
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        if let error = source.openError { print(error); return 1 }
        guard let (device, transport) = connect(source) else {
            print("No VKB stick found.")
            return 1
        }
        print("\(device.name) — \(device.idText)")

        do {
            var link = VKBLink(transport: transport)
            let token = try link.readToken()
            let before = try link.readBlock(token: token)
            guard before.isIntact else {
                print("The stick's own checksum does not match what was read. Stopping; nothing was sent.")
                return 2
            }
            let backup = try BackupStore.save(before, deviceName: device.name)
            print("Backup of the current configuration:\n  \(backup.path)")
            print("Calibration stored now:")
            calibrationLines(before).forEach { print($0) }
            print("""

            This sends the stick's "start calibration" and "commit" commands (\(form == .encoded ? "encoded" : "plain") form).
            Confirmed working on one Gladiator EVO L at firmware 2.20.C; not VKB-documented.

            Step 1 of 2. Take your hands off the stick, then press Return to START.
            Type q and Return to quit without sending anything.
            """)
            guard let first = readLine(), !first.lowercased().hasPrefix("q") else {
                print("Nothing was sent.")
                return 0
            }

            // The stick does not acknowledge this command: on a Gladiator EVO at firmware 2.20.C its
            // reply buffer read the same whether it took the command (encoded) or ignored it (plain).
            let startReply = try link.sendCalibration(.start, form: form, token: token)
            print("Start sent. (Reply buffer: \(hex(startReply)); the stick gives no acknowledgement.)")
            print("""

            If you want to stop now, type s and Return: no commit is sent.

            Step 2 of 2. Move EVERY axis through its full travel, slowly, three times:
              - the stick to all four limits and round the edge;
              - the twist fully left and fully right;
              - the throttle lever from end to end;
              - the ministick to all four limits and round the edge.
            An axis that is not moved may end up with a useless calibration.
            Then let go of everything, wait two seconds, and press Return to COMMIT.
            Type c and Return to abandon: the stick is restarted with its old configuration.
            """)
            let second = readLine()
            if let second, second.lowercased().hasPrefix("s") {
                print("Stopped after start; no commit was sent. Unplug and replug the stick if it behaves oddly.")
                return 0
            }
            if second == nil || second!.lowercased().hasPrefix("c") {
                print("Abandoning: writing the old configuration back, which restarts the stick…")
                let status = try link.writeBlock(before, token: token, replacing: before)
                print("Stick answered: \(status)")
                if status == .written, let back = waitForRestart(source, oldID: device.id, seconds: 15) {
                    var after = VKBLink(transport: back.transport)
                    let stored = try after.readBlock(token: try after.readToken())
                    print(stored == before ? "Verified: the stick holds its old configuration."
                                           : "The stick DIFFERS from the backup. Restore it with --vkb-restore.")
                } else {
                    print("Could not confirm the restart. Unplug the stick, plug it in again and run --vkb-info.")
                }
                return 0
            }

            // On commit the stick stores the result and restarts at once, which can break off the
            // very transfer that carried the command. That shows up here as a failed send (seen as
            // IOReturn 0xE0005000, a stalled pipe) although the commit went through. So a failure
            // here is not treated as one: what counts is what the stick holds afterwards.
            do {
                _ = try link.sendCalibration(.commit, form: form, token: token)
                print("Commit sent.")
            } catch {
                print("Commit sent; the stick dropped the connection while answering (\(error)). That is expected if it restarted.")
            }
            print("Waiting to see whether the stick restarts…")
            let back = waitForRestart(source, oldID: device.id, seconds: 6)
            print(back == nil ? "The stick stayed connected." : "The stick restarted.")
            var after = VKBLink(transport: back?.transport ?? transport)
            let stored = try after.readBlock(token: try after.readToken())
            guard stored.isIntact else {
                print("The stick's checksum does not match after the commit. Restore the backup:")
                print("  StickCheck --vkb-restore \"\(backup.path)\" --yes")
                return 5
            }

            let differences = stored.differences(from: before)
            if differences.isEmpty {
                print("""

                NOTHING CHANGED on the stick: its configuration is byte-identical to before.
                Either it ignored the commands in this form, or the result was not stored.
                \(form == .plain ? "The plain form is known to be ignored by a Gladiator EVO at firmware 2.20.C; run without --plain." : "The encoded form worked on a Gladiator EVO at firmware 2.20.C; this stick may differ.")
                If the stick behaves oddly, unplug it and plug it in again.
                """)
                return 3
            }
            let places = differences.prefix(16).map { String(format: "0x%03X", $0) }.joined(separator: " ")
            print("\nThe stick's configuration changed in \(differences.count) bytes: \(places)\(differences.count > 16 ? " …" : "")")
            print("Calibration before:")
            calibrationLines(before).forEach { print($0) }
            print("Calibration after:")
            calibrationLines(stored).forEach { print($0) }

            // What the computer sees now, hands off.
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            if let frame = source.drain(time: 0) {
                let rest = zip(source.axes, frame.samples).prefix(6).map { "\($0.name) \($1.value)" }.joined(separator: "  ")
                print("At rest now: \(rest)")
            }
            print("""

            Run the guided test in the app to judge the result. To go back to how it was:
              StickCheck --vkb-restore "\(backup.path)" --yes
            """)
            return 0
        } catch {
            print("Failed: \(error)")
            print("If the stick behaves oddly, unplug it and plug it in again; the backup can be restored with --vkb-restore.")
            return 1
        }
    }
}
