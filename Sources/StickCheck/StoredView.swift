import StickCore
import SwiftUI

/// What the stick itself has stored: which sensor feeds each axis, its calibration and the dead
/// zones the firmware applies. Read on request only, because reading sends requests to the stick.
struct StoredView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stored on the stick").font(.headline)
                Spacer()
                Button(model.storedBlock == nil ? "Read from stick" : "Read again") { model.readStoredConfig() }
                    .disabled(model.session.isRunning)
                    .help("Asks the stick for its configuration. Read-only: nothing on the stick is changed.")
            }

            if let error = model.storedError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let block = model.storedBlock {
                Text("Firmware \(block.firmwareText) · checksum verified")
                    .font(.caption).foregroundStyle(.secondary)

                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("Axis").gridColumnAlignment(.leading)
                        Text("Sensor")
                        Text("Bias")
                        Text("KdLo")
                        Text("KdHi")
                        Text("Dead zone").gridColumnAlignment(.leading)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.session.axes) { axis in
                        if let stored = block.storedAxis(named: axis.name) {
                            GridRow {
                                Text(axis.name).fontWeight(.medium)
                                Text("slot \(stored.physical.slot)")
                                Text(String(format: "%+d", stored.physical.bias))
                                Text("\(stored.physical.kdLo)")
                                Text("\(stored.physical.kdHi)")
                                Text(deadzoneText(stored.logical))
                            }
                            .monospacedDigit()
                        }
                    }
                }
                .font(.callout)

                Text("Bias is the zero offset and KdLo/KdHi the gains below and above centre, as worked out by the stick's last calibration. The stick applies its dead zones before the computer sees a value, so a reading of exactly centre only shows that the offset is smaller than the dead zone.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("Save backup") { model.saveBackup() }
                    if model.lastBackup != nil {
                        Button("Show in Finder") { model.revealBackup() }
                        Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            } else if model.storedError == nil {
                Text("Shows the calibration and dead zones kept in the stick's own memory.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func deadzoneText(_ axis: VKBLogicalAxis) -> String {
        let low = axis.deadzoneLow.map { String(format: "%.1f %%", $0) } ?? "shared"
        return "\(low) \(axis.centred ? "centre" : "bottom") · \(String(format: "%.1f %%", axis.deadzoneHigh)) top"
    }
}
