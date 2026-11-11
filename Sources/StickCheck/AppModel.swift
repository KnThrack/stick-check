import AppKit
import Observation
import StickCore
import StickHID

/// Two axes shown together as a square pad.
struct Pad: Identifiable {
    let id: Int
    let title: String
    let x: Int
    let y: Int
}

/// What one axis row draws: the current value and the range seen since the marks were reset.
struct AxisReading: Equatable {
    let value: Int
    let seenLow: Int
    let seenHigh: Int
}

/// Thin shell around the core: polls the stick at 60 Hz, forwards frames and commands to the
/// session, and exposes what the views draw.
@MainActor @Observable
final class AppModel {
    @ObservationIgnored private let source = HIDStickSource()
    @ObservationIgnored private let clock: () -> Double
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var rateWindowStart = 0.0

    private(set) var devices: [DeviceInfo] = []
    private(set) var selectedID: UInt64?
    private(set) var openError: String?
    private(set) var session = Session(axes: [])
    private(set) var report: Report?
    private(set) var samples: [AxisSample] = []
    private(set) var seenLow: [Int] = []
    private(set) var seenHigh: [Int] = []
    private(set) var pressedButtons: [Int] = []
    private(set) var buttonCount = 0
    private(set) var hat: Int?
    private(set) var reportRate = 0
    private(set) var peakReportRate = 0
    private(set) var pads: [Pad] = []
    private(set) var trails: [[CGPoint]] = []
    /// The configuration read from the stick on request; nil until then.
    private(set) var storedBlock: VKBBlock?
    private(set) var storedError: String?
    private(set) var lastBackup: URL?

    init(clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    var selectedDevice: DeviceInfo? { devices.first { $0.id == selectedID } }

    /// Nil when the axis has no reading, for example just after the stick was unplugged.
    func reading(for axis: Int) -> AxisReading? {
        guard samples.indices.contains(axis), seenLow.indices.contains(axis), seenHigh.indices.contains(axis) else { return nil }
        return AxisReading(value: samples[axis].value, seenLow: seenLow[axis], seenHigh: seenHigh[axis])
    }
    var isVKB: Bool { selectedDevice?.vendorID == 0x231D }

    // MARK: - Configuration stored on the stick

    /// Asks the stick for its configuration block. Sends read requests only. Blocks for about
    /// half a second, so it is not offered while the guided test is running.
    func readStoredConfig() {
        storedError = nil
        lastBackup = nil
        guard !session.isRunning, let transport = source.vkbTransport() else {
            storedError = "This stick's configuration cannot be read."
            return
        }
        do {
            var link = VKBLink(transport: transport)
            let token = try link.readToken()
            let block = try link.readBlock(token: token)
            guard block.isIntact else {
                storedBlock = nil
                storedError = "The stick's checksum does not match what was read, so the result is not shown."
                return
            }
            storedBlock = block
        } catch {
            storedBlock = nil
            storedError = "\(error)"
        }
    }

    func saveBackup() {
        guard let storedBlock, let device = selectedDevice else { return }
        do {
            lastBackup = try BackupStore.save(storedBlock, deviceName: device.name)
        } catch {
            storedError = "The backup could not be saved: \(error)"
        }
    }

    func revealBackup() {
        guard let lastBackup else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastBackup])
    }

    /// The centre dead zone the stick itself applies to this axis, in %, when known.
    func stickDeadzone(for axis: AxisInfo) -> Double? {
        storedBlock?.storedAxis(named: axis.name)?.logical.deadzoneLow
    }

    func start() {
        guard timer == nil else { return }
        source.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        source.start()
        openError = source.openError
        devicesChanged()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func select(_ id: UInt64?) {
        source.select(id)
        devicesChanged()
    }

    func send(_ command: Command) {
        session.apply(command)
        refreshReport()
    }

    func resetSeenRange() {
        seenLow = samples.map(\.value)
        seenHigh = samples.map(\.value)
        trails = pads.map { _ in [] }
        peakReportRate = 0
    }

    // MARK: - Report export

    func reportMarkdown() -> String? {
        guard let report, let device = selectedDevice else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd-MM-yyyy HH:mm"
        return report.markdown(title: device.name, subtitle: "\(formatter.string(from: Date())) · \(device.idText)")
    }

    func copyReport() {
        guard let text = reportMarkdown() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func saveReport() {
        guard let text = reportMarkdown() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "stick-check.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: - Internals

    private func devicesChanged() {
        devices = source.devices
        guard selectedID != source.selectedID || session.axes.count != source.axes.count else { return }
        selectedID = source.selectedID
        let axes = source.axes
        session = Session(axes: axes)
        report = nil
        storedBlock = nil
        storedError = nil
        lastBackup = nil
        samples = source.drain(time: clock())?.samples ?? []
        buttonCount = source.buttonCount
        pads = Self.pads(for: axes)
        resetSeenRange()
        reportRate = 0
        rateWindowStart = clock()
        _ = source.takeReportCount()
    }

    private static func pads(for axes: [AxisInfo]) -> [Pad] {
        func index(_ name: String) -> Int? { axes.firstIndex { $0.name == name } }
        var pads: [Pad] = []
        if let x = index("X"), let y = index("Y") { pads.append(Pad(id: 0, title: "X / Y", x: x, y: y)) }
        if let x = index("Rx"), let y = index("Ry") { pads.append(Pad(id: 1, title: "Rx / Ry", x: x, y: y)) }
        return pads
    }

    private func tick() {
        let now = clock()
        guard let frame = source.drain(time: now), frame.samples.count == session.axes.count else { return }

        if session.isRunning {
            session.apply(.frame(frame))
            refreshReport()
        }
        if frame.samples != samples { samples = frame.samples }
        for index in frame.samples.indices where index < seenLow.count {
            if frame.samples[index].low < seenLow[index] { seenLow[index] = frame.samples[index].low }
            if frame.samples[index].high > seenHigh[index] { seenHigh[index] = frame.samples[index].high }
        }
        for (padIndex, pad) in pads.enumerated()
        where padIndex < trails.count && max(pad.x, pad.y) < frame.samples.count {
            let point = CGPoint(x: session.axes[pad.x].fraction(Double(frame.samples[pad.x].value)),
                                y: session.axes[pad.y].fraction(Double(frame.samples[pad.y].value)))
            if trails[padIndex].last != point {
                trails[padIndex].append(point)
                if trails[padIndex].count > 400 { trails[padIndex].removeFirst(trails[padIndex].count - 400) }
            }
        }
        let pressed = source.pressedButtons
        if pressed != pressedButtons { pressedButtons = pressed }
        if source.hat != hat { hat = source.hat }

        if now - rateWindowStart >= 1 {
            let rate = Int((Double(source.takeReportCount()) / (now - rateWindowStart)).rounded())
            rateWindowStart = now
            if rate != reportRate { reportRate = rate }
            if rate > peakReportRate { peakReportRate = rate }
        }
    }

    private func refreshReport() {
        if session.phase == .done {
            let fresh = Analysis.report(for: session)
            if fresh != report { report = fresh }
        } else if report != nil {
            report = nil
        }
    }
}
