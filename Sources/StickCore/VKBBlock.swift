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

/// One output axis as the stick presents it to the computer: which sensor it reads, under which
/// HID usage, and the dead zones the stick itself applies before a game sees anything.
public struct VKBLogicalAxis: Sendable, Equatable, Identifiable {
    public static let usageNames = ["X", "Y", "Z", "Rx", "Ry", "Rz", "Slider", "Dial", "Wheel", "Rudder",
                                    "Throttle", "Accelerator", "Flaps", "Aileron", "Aileron trim", "Elevator"]

    public let slot: Int
    /// The physical axis slot this output reads.
    public let physicalSlot: Int
    public let enabled: Bool
    /// Reported to the computer. A hidden axis can still feed buttons or other axes.
    public let visible: Bool
    public let inverted: Bool
    /// The stick treats it as an axis with a centre.
    public let centred: Bool
    public let usageIndex: Int
    public let precisionBits: Int
    /// Dead zone at the centre (or at the bottom of an axis without a centre), in %.
    /// Nil when this axis is the second half of a circular dead zone and shares its partner's.
    public let deadzoneLow: Double?
    /// Dead zone at the top of the range, in %.
    public let deadzoneHigh: Double
    public let circularDeadzonePartner: Int?

    public var id: Int { slot }
    /// Same names as `AxisInfo.describe` for the usages both can express.
    public var usageName: String { Self.usageNames[usageIndex] }
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

    /// Positions at which two blocks differ.
    public func differences(from other: VKBBlock) -> [Int] {
        bytes.indices.filter { bytes[$0] != other.bytes[$0] }
    }

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

    /// The first eight logical axis slots (records of 8 bytes at 0x3C).
    public var logicalAxes: [VKBLogicalAxis] {
        (0..<8).map { slot in
            let base = 0x3C + 8 * slot
            let circular = bytes[base + 1] & 0x40 != 0
            return VKBLogicalAxis(slot: slot,
                                  physicalSlot: Int(bytes[base] & 0x0F),
                                  enabled: bytes[base] & 0x10 != 0,
                                  visible: bytes[base] & 0x20 != 0,
                                  inverted: bytes[base] & 0x40 != 0,
                                  centred: bytes[base] & 0x80 != 0,
                                  usageIndex: Int(bytes[base + 1] & 0x0F),
                                  precisionBits: Int(bytes[base + 2] & 0x0F),
                                  deadzoneLow: circular ? nil : Double(bytes[base + 3]) / 10,
                                  deadzoneHigh: Double(bytes[base + 4]) / 10,
                                  circularDeadzonePartner: circular ? Int(bytes[base + 3] & 0x0F) : nil)
        }
    }

    /// The enabled output axis reported under this HID usage name ("X", "Rz", …) and the sensor
    /// slot behind it. Nil when no enabled, visible axis uses that name.
    public func storedAxis(named name: String) -> (logical: VKBLogicalAxis, physical: VKBPhysicalAxis)? {
        guard let logical = logicalAxes.first(where: { $0.enabled && $0.visible && $0.usageName == name }),
              logical.physicalSlot < 8
        else { return nil }
        return (logical, physicalAxes[logical.physicalSlot])
    }

    /// A plain-text summary. Contains nothing that identifies one particular stick.
    public var summary: String {
        var lines = [
            "Configuration block: \(bytes.count) bytes, type id 0x\(String(format: "%02X", typeID)), firmware \(firmwareText)",
            String(format: "Checksum: stored %08X, computed %08X — %@", storedCRC, computedCRC,
                   isIntact ? "match" : "MISMATCH"),
            "Output axes (what the computer sees, and the sensor slot behind each):",
        ]
        for axis in logicalAxes where axis.enabled {
            let deadzone = axis.deadzoneLow.map { String(format: "%.1f %%", $0) }
                ?? "shared with axis \(axis.circularDeadzonePartner ?? 0)"
            let flags = [axis.visible ? nil : "hidden",
                         axis.centred ? "centred" : "no centre",
                         axis.inverted ? "inverted" : nil].compactMap { $0 }
            lines.append(String(format: "  %@ ← slot %d, %d bit, dead zone %@ low / %.1f %% high, %@",
                                axis.usageName.padding(toLength: 7, withPad: " ", startingAt: 0),
                                axis.physicalSlot, axis.precisionBits, deadzone, axis.deadzoneHigh,
                                flags.joined(separator: ", ")))
        }
        lines.append("Physical axis slots (calibration as stored on the stick):")
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
