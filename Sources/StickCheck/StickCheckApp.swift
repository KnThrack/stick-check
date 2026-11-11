import AppKit
import StickCore
import StickHID
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--dump") {
            dump()
        } else if arguments.contains("--vkb-info") {
            exit(VKBCommand.run(backup: false))
        } else if arguments.contains("--vkb-backup") {
            exit(VKBCommand.run(backup: true))
        } else if arguments.contains("--vkb-calibrate") {
            exit(VKBCommand.calibrate(form: arguments.contains("--plain") ? .plain : .encoded))
        } else if let index = arguments.firstIndex(of: "--vkb-restore") {
            guard index + 1 < arguments.count else {
                print("Usage: StickCheck --vkb-restore <backup file> [--yes]")
                exit(64)
            }
            exit(VKBCommand.restore(path: arguments[index + 1], confirmed: arguments.contains("--yes")))
        } else {
            StickCheckApp.main()
        }
    }

    /// Headless check: prints what the app sees of each connected stick, then exits.
    @MainActor static func dump() {
        let source = HIDStickSource()
        source.start()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        if let error = source.openError { print(error) }
        if source.devices.isEmpty { print("No joystick found.") }
        for device in source.devices {
            source.select(device.id)
            _ = source.takeReportCount()
            print("\(device.name) — \(device.manufacturer)\n\(device.idText)")
            let frame = source.drain(time: 0)
            for (axis, sample) in zip(source.axes, frame?.samples ?? []) {
                let kind = axis.kind == .centring ? "self-centring" : "slider"
                print("  \(axis.name.padding(toLength: 7, withPad: " ", startingAt: 0)) \(sample.value)  (range \(axis.logicalMin)…\(axis.logicalMax), \(kind))")
            }
            print("  buttons: \(source.buttonCount), pressed: \(source.pressedButtons), hat: \(source.hat.map(String.init) ?? "centred")")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare executable (swift run) rather than from an app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct StickCheckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Stick Check", id: "main") {
            ContentView(model: model)
                .onAppear { model.start() }
        }
        .defaultSize(width: 1040, height: 720)
    }
}

struct ContentView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
            Divider()
            if let error = model.openError {
                ContentUnavailableView("Cannot read joysticks", systemImage: "lock",
                                       description: Text(error + " Check System Settings › Privacy & Security › Input Monitoring."))
            } else if model.selectedDevice == nil {
                ContentUnavailableView("No joystick found", systemImage: "gamecontroller",
                                       description: Text("Plug the stick in; it appears here by itself."))
            } else {
                HStack(spacing: 0) {
                    LiveView(model: model).frame(minWidth: 470, maxWidth: .infinity)
                    Divider()
                    TestView(model: model).frame(minWidth: 440, maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .sheet(isPresented: Binding(get: { model.calibration != nil }, set: { if !$0 { model.closeCalibration() } })) {
            if let step = model.calibration {
                CalibrationSheet(model: model, step: step)
                    .interactiveDismissDisabled()
            }
        }
    }
}

struct HeaderView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "gamecontroller.fill").font(.title2).foregroundStyle(.secondary)
            if model.devices.count > 1 {
                Picker("Device", selection: Binding(get: { model.selectedID }, set: { model.select($0) })) {
                    ForEach(model.devices) { Text($0.name).tag(Optional($0.id)) }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                .disabled(model.session.isRunning)
            }
            if let device = model.selectedDevice {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
                    Text([device.manufacturer, device.idText].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(model.reportRate) reports/s").monospacedDigit()
                    Text("peak \(model.peakReportRate)/s").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .help("The stick only sends a report when something changes, so this is near zero at rest.")
            } else {
                Text("Stick Check").font(.headline)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
