import StickCore
import SwiftUI

/// The guided calibration: backup, start, move every axis, commit, result.
/// Nothing is sent to the stick until Start is pressed.
struct CalibrationSheet: View {
    let model: AppModel
    let step: CalibrationStep

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Calibrate the stick").font(.title2.bold())
            switch step {
            case .ready(let before, let backup): ready(before, backup)
            case .measuring(let before, _): measuring(before)
            case .waiting(_, _, let purpose): waiting(purpose)
            case .finished(let before, let after, let backup): finished(before, after, backup)
            case .unchanged(let backup): unchanged(backup)
            case .putBack(let verified): putBack(verified)
            case .failed(let message, let backup): failed(message, backup)
            }
        }
        .padding(20)
        .frame(width: 540)
    }

    // MARK: - Steps

    private func ready(_ before: VKBBlock, _ backup: URL) -> some View {
        Group {
            Text("The stick measures its own axes and stores the result, replacing its current calibration. This takes about a minute.")
                .fixedSize(horizontal: false, vertical: true)
            backupNote(backup, "A backup of the current configuration is saved, so this can be undone.")
            Text("Step 1 of 2 · Hands off").font(.headline)
            Text("Let go of the stick and every other control, then press Start.")
            HStack {
                Button("Start") { model.startCalibration() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button("Cancel") { model.closeCalibration() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("Nothing has been sent yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func measuring(_ before: VKBBlock) -> some View {
        Group {
            Text("Step 2 of 2 · Move every axis").font(.headline)
            Text("Slowly, three times each: the stick to all four limits and round the edge, the twist fully both ways, the throttle from end to end, the ministick to all four limits. An axis you do not move may end up with a useless calibration.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 6) {
                ForEach(model.session.axes) { axis in
                    if before.storedAxis(named: axis.name) != nil, let reading = model.reading(for: axis.id) {
                        HStack(spacing: 10) {
                            Text(axis.name).fontWeight(.medium).frame(width: 40, alignment: .leading)
                            AxisBar(axis: axis, value: reading.value, seenLow: reading.seenLow, seenHigh: reading.seenHigh)
                                .frame(height: 14)
                            Text(String(format: "%.0f %% seen", 100 * Double(reading.seenHigh - reading.seenLow) / max(axis.span, 1)))
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 84, alignment: .trailing)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Text("The bars show the travel the computer has seen since Start. They are only a guide: the stick does its own measuring.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Then let go of everything, wait two seconds and press Commit.")
            HStack {
                Button("Commit") { model.commitCalibration() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button("Abandon") { model.abandonCalibration() }
                    .help("Restarts the stick with its old configuration. Nothing from this calibration is kept.")
            }
        }
    }

    private func waiting(_ purpose: CalibrationWait) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(purpose == .commit ? "The stick is storing the result and restarting…"
                                    : "The stick is restarting with its earlier configuration…")
        }
        .padding(.vertical, 12)
    }

    private func finished(_ before: VKBBlock, _ after: VKBBlock, _ backup: URL) -> some View {
        Group {
            Label("New calibration stored", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    Text("Axis").gridColumnAlignment(.leading)
                    Text("Bias")
                    Text("KdLo")
                    Text("KdHi")
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(model.session.axes) { axis in
                    if let old = before.storedAxis(named: axis.name)?.physical,
                       let new = after.storedAxis(named: axis.name)?.physical {
                        GridRow {
                            Text(axis.name).fontWeight(.medium)
                            Text(change(old.bias, new.bias, signed: true))
                            Text(change(old.kdLo, new.kdLo))
                            Text(change(old.kdHi, new.kdHi))
                        }
                        .monospacedDigit()
                    }
                }
            }
            .font(.callout)
            Text("These are the stick's zero offset and gains, before → after. Run the guided test now to see whether the result is good.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            backupNote(backup, "The configuration from before this calibration is kept here.")
            HStack {
                Button("Done") { model.closeCalibration() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button("Restore previous") { model.restorePreviousCalibration() }
                    .help("Writes the configuration from before this calibration back to the stick. The stick restarts.")
            }
        }
    }

    private func unchanged(_ backup: URL) -> some View {
        Group {
            Label("Nothing changed on the stick", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text("Its configuration is exactly as before, so the stick did not take the calibration. This is known to work on a Gladiator EVO at firmware 2.20.C; other sticks or firmware may differ. If the stick behaves oddly, unplug it and plug it in again.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Close") { model.closeCalibration() }.keyboardShortcut(.defaultAction)
        }
    }

    private func putBack(_ verified: Bool) -> some View {
        Group {
            if verified {
                Label("The stick holds its earlier configuration again", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
            } else {
                Label("The stick does not match the earlier configuration", systemImage: "xmark.octagon.fill")
                    .font(.headline).foregroundStyle(.red)
                Text("Read it with “Read from stick” and compare, or restore a backup from the command line with --vkb-restore.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Close") { model.closeCalibration() }.keyboardShortcut(.defaultAction)
        }
    }

    private func failed(_ message: String, _ backup: URL?) -> some View {
        Group {
            Label("Calibration stopped", systemImage: "xmark.octagon.fill")
                .font(.headline).foregroundStyle(.red)
            Text(message).fixedSize(horizontal: false, vertical: true)
            if let backup {
                backupNote(backup, "The configuration from before is saved. It can be written back from the command line with --vkb-restore.")
            }
            Button("Close") { model.closeCalibration() }.keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Pieces

    private func backupNote(_ backup: URL, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(backup.lastPathComponent).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    private func change(_ old: Int, _ new: Int, signed: Bool = false) -> String {
        let format = signed ? "%+d → %+d" : "%d → %d"
        return String(format: format, old, new)
    }
}
