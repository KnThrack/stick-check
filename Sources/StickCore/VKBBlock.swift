import Foundation

/// Calibration and sensor settings of one physical axis slot, as stored on the stick.
///
/// The stick holds no minimum/centre/maximum. It holds a zero offset (`bias`) and two gains
/// (`kdLo` below the centre, `kdHi` above); the firmware works them out during calibration.
public struct VKBPhysicalAxis: Sendable, Equatable, Identifiable {
    public let slot: Int
    public let autoCentring: Bool
    public let autoCalibration: Bool
    public let inverted: Bool
    public let kdHi: Int
    public let kdLo: Int
    /// Zero point: 13-bit signed.
    public let bias: Int
    /// The stick's own "this axis has been calibrated" flag.
    public let calibrated: Bool

    public var id: Int { slot }
    /// Unused slots hold the defaults: both gains 255 and no offset.
    public var holdsCalibration: Bool { kdHi != 255 || kdLo != 255 || bias != 0 }
}

/// The stick's whole configuration: one 4096-byte block kept in its flash.
/// Field positions are from the vkbdevcfg-explained project (docs/BLOCK-AXES.md).
public struct VKBBlock: Sendable, Equatable {
    public static let size = 0x1000
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.size else { throw VKBError.wrongBlockSize(bytes.count) }
        self.bytes = bytes
    }

    public var typeID: UInt8 { bytes[2] }
    public var firmware: UInt16 { UInt16(bytes[8]) | UInt16(bytes[9]) << 8 }

    /// 0x220C reads as 2.20.C.
    public var firmwareText: String {
        String(format: "%X.%02X.%X", firmware >> 12, (firmware >> 4) & 0xFF, firmware & 0xF)
    }

    public var storedCRC: UInt32 {
        UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
    }

    public var computedCRC: UInt32 { VKBBytes.crc32STM32(bytes[8...]) }

    /// True when the stick's own checksum matches. That proves the transport, the token and the
    /// cipher were all right, so the block is what the stick really holds.
    public var isIntact: Bool { storedCRC == computedCRC }

    public var calibratedMask: UInt8 { bytes[0x0C] }

    /// The first eight physical axis slots (records of 8 bytes at 0x7C).
    public var physicalAxes: [VKBPhysicalAxis] {
        (0..<8).map { slot in
            let base = 0x7C + 8 * slot
            let word = Int(bytes[base + 6]) | Int(bytes[base + 7]) << 8
            let raw = word & 0x1FFF
            return VKBPhysicalAxis(slot: slot,
                                   autoCentring: bytes[base] & 0x01 != 0,
                                   autoCalibration: bytes[base] & 0x02 != 0,
                                   inverted: bytes[base] & 0x04 != 0,
                                   kdHi: Int(bytes[base + 4]),
                                   kdLo: Int(bytes[base + 5]),
                                   bias: raw >= 0x1000 ? raw - 0x2000 : raw,
                                   calibrated: calibratedMask & (1 << UInt8(slot)) != 0)
        }
    }

    /// A plain-text summary. Contains nothing that identifies one particular stick.
    public var summary: String {
        var lines = [
            "Configuration block: \(bytes.count) bytes, type id 0x\(String(format: "%02X", typeID)), firmware \(firmwareText)",
            String(format: "Checksum: stored %08X, computed %08X — %@", storedCRC, computedCRC,
                   isIntact ? "match" : "MISMATCH"),
            "Physical axis slots (calibration as stored on the stick):",
        ]
        for axis in physicalAxes {
            let flags = [axis.calibrated ? "calibrated" : "not calibrated",
                         axis.autoCentring ? "auto-centre" : nil,
                         axis.autoCalibration ? "auto-calibrate" : nil,
                         axis.inverted ? "inverted" : nil,
                         axis.holdsCalibration ? nil : "unused (defaults)"].compactMap { $0 }
            lines.append(String(format: "  %d  KdLo %3d  KdHi %3d  Bias %+5d  %@",
                                axis.slot, axis.kdLo, axis.kdHi, axis.bias, flags.joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }
}
