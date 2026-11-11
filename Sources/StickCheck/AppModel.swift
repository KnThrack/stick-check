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

/// Where the calibration sheet is. Each case carries what its screen needs.
enum CalibrationStep: Equatable {
    /// Backup saved, nothing sent yet.
    case ready(before: VKBBlock, backup: URL)
    /// "Start" was sent; the stick is measuring while the axes are moved.
    case measuring(before: VKBBlock, backup: URL)
    /// Waiting for the stick to store something and come back.
    case waiting(before: VKBBlock, backup: URL, purpose: CalibrationWait)
    case finished(before: VKBBlock, after: VKBBlock, backup: URL)
    /// The commit left the stick's configuration exactly as it was.
    case unchanged(backup: URL)
    /// The earlier configuration was written back; `verified` says whether the stick confirmed it.
    case putBack(verified: Bool)
    case failed(String, backup: URL?)
}

enum CalibrationWait: Equatable {
    case commit
    case putBack
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
    /// Non-nil while the calibration sheet is open.
    private(set) var calibration: CalibrationStep?
    /// The stick's session token for the calibration in progress. It is the stick's serial
    /// number, so it is never shown or stored.
    @ObservationIgnored private var calibrationToken: [UInt8] = []
    @ObservationIgnored private var restartWatch: RestartWatch?

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

    // MARK: - Calibration

    /// Opens the calibration sheet: reads the stick and saves a backup. Sends read requests only.
    func beginCalibration() {
        guard !session.isRunning, calibration == nil,
              let device = selectedDevice, let transport = source.vkbTransport() else { return }
        do {
            var link = VKBLink(transport: transport)
            let token = try link.readToken()
            let before = try link.readBlock(token: token)
            guard before.isIntact else {
                calibration = .failed("The stick's checksum does not match what was read, so nothing was started.", backup: nil)
                return
            }
            let backup = try BackupStore.save(before, deviceName: device.name)
            calibrationToken = token
            storedBlock = before
            storedError = nil
            calibration = .ready(before: before, backup: backup)
        } catch {
            calibration = .failed("\(error)", backup: nil)
        }
    }

    /// Sends "start calibration". From here the stick measures until it is told to commit.
    func startCalibration() {
        guard case .ready(let before, let backup) = calibration else { return }
        guard let transport = source.vkbTransport() else {
            calibration = .failed("The stick is no longer connected. Nothing was sent.", backup: backup)
            return
        }
        do {
            _ = try VKBLink(transport: transport).sendCalibration(.start, form: .encoded, token: calibrationToken)
            resetSeenRange()
            calibration = .measuring(before: before, backup: backup)
        } catch {
            calibration = .failed("The start command could not be sent: \(error)", backup: backup)
        }
    }

    /// Sends "commit". The stick stores the result and restarts, which can fail the very transfer
    /// that carried the command, so a failed send is not treated as a failure: what counts is what
    /// the stick holds when it is back.
    func commitCalibration() {
        guard case .measuring(let before, let backup) = calibration else { return }
        guard let transport = source.vkbTransport(), let id = selectedID else {
            calibration = .failed("The stick is no longer connected. Plug it in again; the commit was not sent.", backup: backup)
            return
        }
        _ = try? VKBLink(transport: transport).sendCalibration(.commit, form: .encoded, token: calibrationToken)
        restartWatch = RestartWatch(oldDevice: id, started: clock())
        calibration = .waiting(before: before, backup: backup, purpose: .commit)
    }

    /// Gives up a calibration that is being measured: writes the old configuration back, which
    /// restarts the stick and so ends its calibration mode without storing anything.
    func abandonCalibration() {
        guard case .measuring(let before, let backup) = calibration else { return }
        putBack(before, replacing: before, backup: backup)
    }

    /// After a finished calibration: goes back to the configuration from before it.
    func restorePreviousCalibration() {
        guard case .finished(let before, let after, let backup) = calibration else { return }
        putBack(before, replacing: after, backup: backup)
    }

    private func putBack(_ block: VKBBlock, replacing current: VKBBlock, backup: URL) {
        guard let transport = source.vkbTransport(), let id = selectedID else {
            calibration = .failed("The stick is no longer connected, so the earlier configuration was not written back.", backup: backup)
            return
        }
        do {
            var link = VKBLink(transport: transport)
            let status = try link.writeBlock(block, token: calibrationToken, replacing: current)
            guard status == .written else {
                calibration = .failed("The stick did not accept the earlier configuration (\(status)).", backup: backup)
                return
            }
            restartWatch = RestartWatch(oldDevice: id, started: clock())
            calibration = .waiting(before: block, backup: backup, purpose: .putBack)
        } catch {
            calibration = .failed("The earlier configuration could not be written back: \(error)", backup: backup)
        }
    }

    /// Closes the sheet. Not possible while the stick is measuring or restarting: those have to
    /// be finished with Commit or Abandon first.
    func closeCalibration() {
        switch calibration {
        case .measuring, .waiting: return
        default:
            calibration = nil
            calibrationToken = []
            restartWatch = nil
        }
    }

    /// Called every tick: once the stick is back after a commit or a write, reads what it holds.
    private func advanceCalibrationWait(now: Double) {
        guard case .waiting(let before, let backup, let purpose) = calibration, var watch = restartWatch else { return }
        let verdict = watch.check(now: now, device: source.selectedID)
        restartWatch = watch
        switch verdict {
        case .wait:
            return
        case .lost:
            restartWatch = nil
            calibration = .failed("The stick did not come back. Unplug it and plug it in again, then read it.", backup: backup)
        case .ready:
            restartWatch = nil
            guard let transport = source.vkbTransport() else {
                calibration = .failed("The stick came back but could not be opened.", backup: backup)
                return
            }
            do {
                var link = VKBLink(transport: transport)
                let token = try link.readToken()
                let stored = try link.readBlock(token: token)
                guard stored.isIntact else {
                    calibration = .failed("The stick's checksum does not match after the restart.", backup: backup)
                    return
                }
                calibrationToken = token
                storedBlock = stored
                switch purpose {
                case .commit:
                    calibration = stored == before ? .unchanged(backup: backup)
                                                   : .finished(before: before, after: stored, backup: backup)
                case .putBack:
                    calibration = .putBack(verified: stored == before)
                }
            } catch {
                calibration = .failed("The stick could not be read after the restart: \(error)", backup: backup)
            }
        }
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
        advanceCalibrationWait(now: now)
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
