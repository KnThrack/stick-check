import Foundation
import IOKit
import IOKit.hid
import StickCore

public enum HIDFeatureError: Error, CustomStringConvertible {
    case setReport(IOReturn)
    case getReport(IOReturn)

    public var description: String {
        switch self {
        case .setReport(let code): String(format: "Sending the feature report failed (IOReturn 0x%08X).", UInt32(bitPattern: code))
        case .getReport(let code): String(format: "Reading the feature report failed (IOReturn 0x%08X).", UInt32(bitPattern: code))
        }
    }
}

/// Carries VKB's configuration frames over HID feature report 0x59. Calls block for a few
/// milliseconds each; use it from one thread only.
public final class HIDFeatureTransport: FeatureTransport {
    private let device: IOHIDDevice
    private let reportID = VKBLink.reportID

    init(device: IOHIDDevice) {
        self.device = device
    }

    public func send(_ frame: [UInt8]) throws {
        let report = [reportID] + frame
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), report, report.count)
        guard result == kIOReturnSuccess else { throw HIDFeatureError.setReport(result) }
    }

    public func receive() throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: VKBLink.frameSize + 1)
        var length = CFIndex(buffer.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), &buffer, &length)
        guard result == kIOReturnSuccess else { throw HIDFeatureError.getReport(result) }
        // With numbered reports the first byte is the report ID; the frame is the 128 bytes after it.
        let bytes = Array(buffer.prefix(length))
        return bytes.count > VKBLink.frameSize ? Array(bytes.suffix(VKBLink.frameSize)) : bytes
    }

    public func pause(milliseconds: Int) {
        usleep(UInt32(max(0, milliseconds)) * 1000)
    }
}

extension HIDStickSource {
    /// A link to the selected stick's configuration, or nil when it is not a VKB device.
    public func vkbTransport() -> HIDFeatureTransport? {
        guard let device = selectedHIDDevice, selectedDeviceInfo?.vendorID == 0x231D else { return nil }
        return HIDFeatureTransport(device: device)
    }
}
