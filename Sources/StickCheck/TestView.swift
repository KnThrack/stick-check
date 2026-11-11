import StickCore
import SwiftUI

extension Severity {
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle.fill"
        case .marginal: "exclamationmark.triangle.fill"
        case .bad: "xmark.octagon.fill"
        }
    }

    var colour: Color {
        switch self {
        case .ok: .green
        case .marginal: .orange
        case .bad: .red
        }
    }
}

/// Right column: the guided test and its results.
struct TestView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Guided test").font(.title3.bold())
                switch model.session.phase {
                case .idle: idle
                case .rest: rest
                case .range: range
                case .recentre: recentre
                case .done:
                    if let report = model.report { ResultsView(model: model, report: report) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Three steps, about a minute. It only reads the stick; nothing on it is changed.")
            Text("First check the type of each axis on the left: an axis that springs back when you let go is self-centring, a throttle or dial is a slider.")
                .foregroundStyle(.secondary)
            Button("Start test") { model.send(.start) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var rest: some View {
        StepView(number: 1, title: "Hands off") {
            Text("Let go of the stick and leave every axis alone. Measuring where each one rests and how much it jitters.")
            ProgressView(value: 1 - model.session.restRemaining / model.session.settings.restDuration)
            if model.session.restDisturbed {
                Label("The stick moved, so the measurement started over.", systemImage: "hand.raised")
                    .foregroundStyle(.orange)
            }
            Button("Cancel") { model.send(.cancel) }
        }
    }

    private var range: some View {
        StepView(number: 2, title: "Full travel") {
            Text("Move the stick slowly to all four limits and run it round the edge twice. Twist fully both ways. Move the throttle and every other axis from end to end.")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(zip(model.session.axes, model.session.measurements)), id: \.0.id) { axis, m in
                    GridRow {
                        Text(axis.name).fontWeight(.medium)
                        Text("\(m.rangeLow.map(String.init) ?? "–") … \(m.rangeHigh.map(String.init) ?? "–")").monospacedDigit()
                        Text("of \(axis.logicalMin) … \(axis.logicalMax)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            HStack {
                Button("Next") { model.send(.next) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button("Cancel") { model.send(.cancel) }
            }
        }
    }

    private var recentre: some View {
        StepView(number: 3, title: "Release") {
            Text("Push the stick fully to one side, let it snap back and leave it alone for a second. Do that left, right, forward and back, and for both twist directions, three times each.")
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(zip(model.session.axes, model.session.measurements)), id: \.0.id) { axis, m in
                    if axis.kind == .centring {
                        GridRow {
                            Text(axis.name).fontWeight(.medium)
                            Text("\(m.settleCount(from: .low)) from the low side").monospacedDigit()
                            Text("\(m.settleCount(from: .high)) from the high side").monospacedDigit()
                        }
                    }
                }
            }
            HStack {
                Button("Finish") { model.send(.next) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                Button("Cancel") { model.send(.cancel) }
            }
        }
    }
}

struct StepView<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Step \(number) of 3 · \(title)").font(.headline)
            content
        }
    }
}

struct ResultsView: View {
    let model: AppModel
    let report: Report

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            overall
            ForEach(report.axes) { AxisResult(report: $0) }
            if report.restDisturbed {
                Text("The stick moved during step 1, so that measurement was started over.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Centre offset and return spread are % of half the range; jitter and missing travel are % of the full range.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Run again") { model.send(.start) }
                Button("Copy report") { model.copyReport() }
                Button("Save report…") { model.saveReport() }
            }
        }
    }

    @ViewBuilder private var overall: some View {
        if let severity = report.overall {
            VStack(alignment: .leading, spacing: 6) {
                Label(severity.label, systemImage: severity.symbol)
                    .font(.title3.bold()).foregroundStyle(severity.colour)
                Text(advice(severity)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(severity.colour.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Label("No axis was moved, so nothing could be judged.", systemImage: "minus.circle")
        }
    }

    private func advice(_ severity: Severity) -> String {
        switch severity {
        case .ok:
            "Nothing here calls for recalibrating. Use the dead zones below in your games if you want a fully quiet centre."
        case .marginal:
            "Usable as it is. The dead zones below hide what was measured; recalibrate only if it bothers you in play."
        case .bad:
            "At least one axis is off by more than a dead zone should hide. Recalibrate the stick with VKB's VKBDevCfg (Windows, or a Windows VM with the stick passed through), then run this test again."
        }
    }
}

struct AxisResult: View {
    let report: AxisReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(report.axis.name).font(.headline)
                Text(report.axis.kind == .centring ? "self-centring" : "slider").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if report.tested {
                    Label(report.verdict, systemImage: report.severity.symbol).foregroundStyle(report.severity.colour)
                } else {
                    Label(report.verdict, systemImage: "minus.circle").foregroundStyle(.secondary)
                }
            }
            if report.tested {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                    if let offset = report.centreOffsetPercent, let rest = report.restValue {
                        row("Rests at", String(format: "%.0f (%+.2f %% from centre)", rest, offset))
                    } else if let rest = report.restValue {
                        row("Rested at", String(format: "%.0f", rest))
                    }
                    if let low = report.rangeLow, let high = report.rangeHigh {
                        row("Range reached", "\(low) … \(high) of \(report.axis.logicalMin) … \(report.axis.logicalMax)")
                    }
                    if let counts = report.noiseCounts, let percent = report.noisePercent {
                        row("Jitter at rest", String(format: "%d counts (%.2f %%)", counts, percent))
                    }
                    if let spread = report.settleSpreadPercent {
                        let low = report.settleFromLow.map { String(format: "%.0f from low", $0) }
                        let high = report.settleFromHigh.map { String(format: "%.0f from high", $0) }
                        row("Returns to", ([low, high].compactMap { $0 }).joined(separator: ", ")
                            + String(format: " (%.2f %% spread, %d releases)", spread, report.settleCount))
                    }
                    if let deadzone = report.suggestedDeadzonePercent {
                        row("Dead zone", deadzone == 0 ? "none needed" : String(format: "%.1f %%", deadzone))
                    }
                }
                .font(.callout)
            }
            ForEach(Array(report.findings.enumerated()), id: \.offset) { _, finding in
                Text(finding.text)
                    .font(.callout)
                    .foregroundStyle(finding.severity == .ok ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
    }
}
