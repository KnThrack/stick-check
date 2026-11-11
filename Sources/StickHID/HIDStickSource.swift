import Foundation
import IOKit
import IOKit.hid
import StickCore

public struct DeviceInfo: Sendable, Equatable, Identifiable {
    /// IORegistry entry ID: unique while the device stays plugged in.
    public let id: UInt64
    public let name: String
    public let manufacturer: String
    public let vendorID: Int
    public let productID: Int
    public let version: Int

    public var idText: String {
        String(format: "VID %04X · PID %04X · device version %04X", vendorID, productID, version)
    }
}

/// Reads joysticks through IOKit HID. It listens to input reports and sends nothing itself.
/// The only path that sends anything to a device is `vkbTransport()`, used for read requests.
@MainActor
public final class HIDStickSource {
    private final class Entry {
        let device: IOHIDDevice
        let info: DeviceInfo
        var axes: [AxisInfo] = []
        var samples: [AxisSample] = []
        var axisIndex: [IOHIDElementCookie: Int] = [:]
        var buttonNumber: [IOHIDElementCookie: Int] = [:]
        var hatRange: [IOHIDElementCookie: ClosedRange<Int>] = [:]
        var pressed: Set<Int> = []
        var hat: Int?
        var reportCount = 0
        var lastTimestamp: UInt64 = 0

        init(device: IOHIDDevice, info: DeviceInfo) {
            self.device = device
            self.info = info
        }
    }

    public private(set) var devices: [DeviceInfo] = []
    public private(set) var selectedID: UInt64?
    /// Set when macOS refused to open the HID manager (for example a privacy restriction).
    public private(set) var openError: String?
    public var onDevicesChanged: (@MainActor () -> Void)?

    private var manager: IOHIDManager?
    private var entries: [UInt64: Entry] = [:]
    private var idByDevice: [IOHIDDevice: UInt64] = [:]

    public init() {}

    public func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Generic Desktop: joystick (4), gamepad (5), multi-axis controller (8).
        let matches = [4, 5, 8].map { [kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: $0] }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let source = Unmanaged<HIDStickSource>.fromOpaque(context).takeUnretainedValue()
            nonisolated(unsafe) let device = device
            MainActor.assumeIsolated { source.attach(device) }
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let source = Unmanaged<HIDStickSource>.fromOpaque(context).takeUnretainedValue()
            nonisolated(unsafe) let device = device
            MainActor.assumeIsolated { source.detach(device) }
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            let source = Unmanaged<HIDStickSource>.fromOpaque(context).takeUnretainedValue()
            nonisolated(unsafe) let value = value
            MainActor.assumeIsolated { source.handle(value) }
        }, context)

        // Callbacks arrive on the main run loop, also while the UI is tracking the mouse.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            openError = String(format: "macOS refused access to HID devices (IOReturn 0x%08X).", UInt32(bitPattern: result))
        }
        self.manager = manager
    }

    public func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        entries = [:]
        idByDevice = [:]
        devices = []
        selectedID = nil
    }

    public func select(_ id: UInt64?) {
        guard id == nil || entries[id!] != nil else { return }
        selectedID = id
    }

    // MARK: - Selected device

    private var selected: Entry? { selectedID.flatMap { entries[$0] } }

    var selectedHIDDevice: IOHIDDevice? { selected?.device }
    public var selectedDeviceInfo: DeviceInfo? { selected?.info }

    public var axes: [AxisInfo] { selected?.axes ?? [] }
    public var pressedButtons: [Int] { selected?.pressed.sorted() ?? [] }
    public var buttonCount: Int { selected?.buttonNumber.count ?? 0 }
    /// Hat direction in 45° steps clockwise from up (0…7), nil when centred or absent.
    public var hat: Int? { selected?.hat }

    /// The current readings, with the extremes seen since the last call.
    public func drain(time: Double) -> Frame? {
        guard let entry = selected else { return nil }
        let frame = Frame(time: time, samples: entry.samples)
        for index in entry.samples.indices {
            entry.samples[index].low = entry.samples[index].value
            entry.samples[index].high = entry.samples[index].value
        }
        return frame
    }

    /// Input reports received since the last call.
    public func takeReportCount() -> Int {
        guard let entry = selected else { return 0 }
        defer { entry.reportCount = 0 }
        return entry.reportCount
    }

    // MARK: - Device handling

    private func attach(_ device: IOHIDDevice) {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        guard id != 0, entries[id] == nil else { return }

        func text(_ key: String) -> String {
            ((IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func number(_ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? Int) ?? 0
        }
        let info = DeviceInfo(id: id,
                              name: text(kIOHIDProductKey).isEmpty ? "Unnamed controller" : text(kIOHIDProductKey),
                              manufacturer: text(kIOHIDManufacturerKey),
                              vendorID: number(kIOHIDVendorIDKey),
                              productID: number(kIOHIDProductIDKey),
                              version: number(kIOHIDVersionNumberKey))
        let entry = Entry(device: device, info: info)

        let elements = ((IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]) ?? [])
            .sorted { IOHIDElementGetCookie($0) < IOHIDElementGetCookie($1) }
        for element in elements {
            let type = IOHIDElementGetType(element)
            let isButtonType = type == kIOHIDElementTypeInput_Button
            guard isButtonType || type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Axis else { continue }
            let page = Int(IOHIDElementGetUsagePage(element))
            let usage = Int(IOHIDElementGetUsage(element))
            let cookie = IOHIDElementGetCookie(element)
            let low = IOHIDElementGetLogicalMin(element)
            let high = IOHIDElementGetLogicalMax(element)

            if page == 0x09 {
                entry.buttonNumber[cookie] = usage
            } else if isButtonType {
                continue  // padding and vendor-defined bits
            } else if page == 0x01, usage == 0x39 {
                if high > low { entry.hatRange[cookie] = low...high }
            } else if high - low >= 255, IOHIDElementGetReportSize(element) <= 32 {
                let described = AxisInfo.describe(usagePage: page, usage: usage, ordinal: entry.axes.count + 1)
                entry.axisIndex[cookie] = entry.axes.count
                entry.axes.append(AxisInfo(id: entry.axes.count, name: described.name,
                                           logicalMin: low, logicalMax: high, kind: described.kind))
                entry.samples.append(AxisSample(Self.currentValue(device, element) ?? (low + high + 1) / 2))
            }
        }

        entries[id] = entry
        idByDevice[device] = id
        devices.append(info)
        if selectedID == nil { selectedID = id }
        onDevicesChanged?()
    }

    private func detach(_ device: IOHIDDevice) {
        guard let id = idByDevice.removeValue(forKey: device) else { return }
        entries[id] = nil
        devices.removeAll { $0.id == id }
        if selectedID == id { selectedID = devices.first?.id }
        onDevicesChanged?()
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard let id = idByDevice[IOHIDElementGetDevice(element)], let entry = entries[id] else { return }

        let timestamp = IOHIDValueGetTimeStamp(value)
        if timestamp != entry.lastTimestamp {
            entry.lastTimestamp = timestamp
            entry.reportCount += 1
        }

        let cookie = IOHIDElementGetCookie(element)
        if let index = entry.axisIndex[cookie] {
            let reading = IOHIDValueGetIntegerValue(value)
            entry.samples[index].value = reading
            entry.samples[index].low = min(entry.samples[index].low, reading)
            entry.samples[index].high = max(entry.samples[index].high, reading)
        } else if let number = entry.buttonNumber[cookie] {
            if IOHIDValueGetIntegerValue(value) != 0 { entry.pressed.insert(number) } else { entry.pressed.remove(number) }
        } else if let range = entry.hatRange[cookie] {
            let reading = IOHIDValueGetIntegerValue(value)
            // Outside the logical range is the hat's "centred" state.
            entry.hat = range.contains(reading) ? (reading - range.lowerBound) * 8 / range.count : nil
        }
    }

    private static func currentValue(_ device: IOHIDDevice, _ element: IOHIDElement) -> Int? {
        let pointer = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard IOHIDDeviceGetValue(device, element, pointer) == kIOReturnSuccess else { return nil }
        return IOHIDValueGetIntegerValue(pointer.pointee.takeUnretainedValue())
    }
}
