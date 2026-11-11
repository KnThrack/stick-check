import StickCore
import SwiftUI

/// Left column: what the stick is reporting right now.
struct LiveView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Live").font(.title3.bold())
                    Spacer()
                    Button("Reset marks") { model.resetSeenRange() }
                        .help("Clears the trail and the range-seen marks.")
                }

                if !model.pads.isEmpty {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(model.pads.enumerated()), id: \.element.id) { index, pad in
                            PadView(model: model, pad: pad, trail: model.trails.indices.contains(index) ? model.trails[index] : [])
                        }
                    }
                }

                VStack(spacing: 8) {
                    ForEach(model.session.axes) { axis in
                        if let reading = model.reading(for: axis.id) {
                            AxisRow(model: model, axis: axis, reading: reading)
                        }
                    }
                }

                ButtonsView(model: model)

                if model.isVKB {
                    Divider()
                    StoredView(model: model)
                }
            }
            .padding(16)
        }
    }
}

struct AxisRow: View {
    let model: AppModel
    let axis: AxisInfo
    /// Handed in by the parent. A row must not index the model's arrays itself: when the stick is
    /// unplugged SwiftUI can re-run a row's body after the arrays have emptied and before the row
    /// is removed, which crashed the app.
    let reading: AxisReading

    var body: some View {
        let value = reading.value
        let percent = axis.kind == .centring
            ? 100 * (Double(value) - axis.mid) / max(axis.halfRange, 1)
            : 100 * axis.fraction(Double(value))
        HStack(spacing: 10) {
            Text(axis.name).font(.body.weight(.medium)).frame(width: 52, alignment: .leading)
            AxisBar(axis: axis, value: value, seenLow: reading.seenLow, seenHigh: reading.seenHigh)
                .frame(height: 18)
            Text("\(value)").monospacedDigit().frame(width: 44, alignment: .trailing)
            Text(String(format: axis.kind == .centring ? "%+.1f %%" : "%.1f %%", percent))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 62, alignment: .trailing)
            Picker("Type of \(axis.name)", selection: Binding(get: { axis.kind },
                                                              set: { model.send(.setKind(axis: axis.id, kind: $0)) })) {
                Text("Self-centring").tag(AxisKind.centring)
                Text("Slider").tag(AxisKind.slider)
            }
            .labelsHidden()
            .frame(width: 122)
            .disabled(model.session.isRunning)
            .help("Self-centring: springs back when released (stick, twist, ministick). Slider: stays where you put it (throttle, dial).")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(axis.name) axis")
        .accessibilityValue("\(value), \(String(format: "%.0f", percent)) percent")
    }
}

/// A horizontal bar: the reported value, the nominal centre, and the range seen so far.
struct AxisBar: View {
    let axis: AxisInfo
    let value: Int
    let seenLow: Int
    let seenHigh: Int

    var body: some View {
        Canvas { context, size in
            let track = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: track, cornerRadius: 4), with: .color(.gray.opacity(0.18)))

            func x(_ v: Double) -> CGFloat { size.width * axis.fraction(v) }
            let seen = CGRect(x: x(Double(seenLow)), y: size.height - 3,
                              width: max(1, x(Double(seenHigh)) - x(Double(seenLow))), height: 3)
            context.fill(Path(seen), with: .color(.secondary))

            let origin = axis.kind == .centring ? x(axis.mid) : 0
            let current = x(Double(value))
            let fill = CGRect(x: min(origin, current), y: 2, width: abs(current - origin), height: size.height - 7)
            context.fill(Path(fill), with: .color(.accentColor.opacity(0.55)))
            context.fill(Path(CGRect(x: current - 1, y: 0, width: 2, height: size.height - 3)), with: .color(.accentColor))

            if axis.kind == .centring {
                context.fill(Path(CGRect(x: x(axis.mid) - 0.5, y: 0, width: 1, height: size.height)), with: .color(.primary.opacity(0.6)))
            }
        }
        .accessibilityHidden(true)
    }
}

/// Two axes as a square: crosshair at the nominal centre, the trail, and the current position.
struct PadView: View {
    let model: AppModel
    let pad: Pad
    let trail: [CGPoint]

    var body: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                let frame = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: frame, cornerRadius: 6), with: .color(.gray.opacity(0.14)))
                var cross = Path()
                cross.move(to: CGPoint(x: size.width / 2, y: 0)); cross.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                cross.move(to: CGPoint(x: 0, y: size.height / 2)); cross.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(cross, with: .color(.primary.opacity(0.25)), lineWidth: 1)

                func point(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * size.width, y: p.y * size.height) }
                if trail.count > 1 {
                    var path = Path()
                    path.addLines(trail.map(point))
                    context.stroke(path, with: .color(.accentColor.opacity(0.45)), lineWidth: 1)
                }
                if let last = trail.last {
                    let p = point(last)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.accentColor))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 220)
            .accessibilityHidden(true)
            Text(pad.title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ButtonsView: View {
    let model: AppModel
    private static let hatNames = ["up", "up-right", "right", "down-right", "down", "down-left", "left", "up-left"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Buttons and hat").font(.headline)
            HStack(spacing: 6) {
                if model.pressedButtons.isEmpty {
                    Text("No button pressed (\(model.buttonCount) available)").foregroundStyle(.secondary)
                } else {
                    Text("Pressed:").foregroundStyle(.secondary)
                    ForEach(model.pressedButtons, id: \.self) { number in
                        Text("\(number)").monospacedDigit()
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            Text("Hat: \(model.hat.map { Self.hatNames[$0 % 8] } ?? "centred")").foregroundStyle(.secondary)
        }
    }
}
