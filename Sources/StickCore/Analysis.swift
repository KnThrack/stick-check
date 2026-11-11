import Foundation

public enum Severity: Int, Sendable, Comparable {
    case ok
    case marginal
    case bad

    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }

    public var label: String {
        switch self {
        case .ok: "OK"
        case .marginal: "Marginal"
        case .bad: "Needs recalibration"
        }
    }
}

public struct Finding: Sendable, Equatable {
    public var severity: Severity
    public var text: String

    public init(_ severity: Severity, _ text: String) {
        self.severity = severity
        self.text = text
    }
}

public struct AxisReport: Sendable, Equatable, Identifiable {
    public var axis: AxisInfo
    /// False when the axis was not moved, so it could not be judged.
    public var tested = false
    public var restValue: Double?
    /// Rest position relative to the nominal centre, % of half the range. Self-centring axes only.
    public var centreOffsetPercent: Double?
    public var noiseCounts: Int?
    /// Peak-to-peak jitter at rest, % of the range.
    public var noisePercent: Double?
    public var rangeLow: Int?
    public var rangeHigh: Int?
    /// Travel never reported at each end, % of the range.
    public var lowShortfallPercent: Double?
    public var highShortfallPercent: Double?
    public var settleCount = 0
    public var settleFromLow: Double?
    public var settleFromHigh: Double?
    /// Spread of the resting places after release, % of half the range.
    public var settleSpreadPercent: Double?
    /// Dead zone (% of half the range) that hides everything seen at rest. 0 means none needed.
    /// Nil for sliders, and when `needsRecalibrationNotDeadzone` is set.
    public var suggestedDeadzonePercent: Double?
    /// The centre is too far off for a dead zone to be a sensible fix.
    public var needsRecalibrationNotDeadzone = false
    public var findings: [Finding] = []
    public var severity: Severity = .ok

    public var id: Int { axis.id }
    public var verdict: String { tested ? severity.label : "Not tested" }
}

public struct Report: Sendable, Equatable {
    public var axes: [AxisReport]
    /// The stick moved during the rest step, so that measurement was started over.
    public var restDisturbed: Bool

    /// Worst verdict among the axes that were tested; nil when none were.
    public var overall: Severity? {
        axes.filter(\.tested).map(\.severity).max()
    }
}

public enum Analysis {
    public static func report(for session: Session) -> Report {
        let axes = zip(session.axes, session.measurements).map { axis, measurement in
            axisReport(axis, measurement, session.settings)
        }
        return Report(axes: axes, restDisturbed: session.restDisturbed)
    }

    static func axisReport(_ axis: AxisInfo, _ m: AxisMeasurement, _ s: Settings) -> AxisReport {
        var r = AxisReport(axis: axis)
        r.rangeLow = m.rangeLow
        r.rangeHigh = m.rangeHigh
        if m.rest.count > 0, axis.span > 0 {
            r.restValue = m.rest.mean
            r.noiseCounts = m.rest.peakToPeak
            r.noisePercent = 100 * Double(m.rest.peakToPeak) / axis.span
        }
        guard m.rest.count > 0, axis.span > 0, let low = m.rangeLow, let high = m.rangeHigh,
              Double(high - low) >= s.minTravelFraction * axis.span
        else {
            r.findings = [Finding(.ok, "Not moved during the test, so not judged.")]
            return r
        }
        r.tested = true
        var findings: [Finding] = []

        // Ends of travel.
        let lowShort = max(0, 100 * Double(low - axis.logicalMin) / axis.span)
        let highShort = max(0, 100 * Double(axis.logicalMax - high) / axis.span)
        r.lowShortfallPercent = lowShort
        r.highShortfallPercent = highShort
        for (short, reached, end, name) in [(lowShort, low, axis.logicalMin, "low"), (highShort, high, axis.logicalMax, "high")] {
            let grade = grade(short, s.shortfallMarginal, s.shortfallBad)
            if grade > .ok {
                findings.append(Finding(grade, "Stops at \(reached) instead of \(end): the last \(fmt(short)) % of the range at the \(name) end is never reported."))
            }
        }

        // Jitter at rest.
        let noise = 100 * Double(m.rest.peakToPeak) / axis.span
        let noiseGrade = grade(noise, s.noiseMarginal, s.noiseBad)
        if noiseGrade > .ok {
            findings.append(Finding(noiseGrade, "Jitters by \(m.rest.peakToPeak) counts (\(fmt(noise, 2)) % of the range) while untouched."))
        }

        if axis.kind == .centring {
            let offset = 100 * (m.rest.mean - axis.mid) / axis.halfRange
            r.centreOffsetPercent = offset
            let offsetGrade = grade(abs(offset), s.centreOffsetMarginal, s.centreOffsetBad)
            if offsetGrade > .ok {
                findings.append(Finding(offsetGrade, "Rests at \(fmt(m.rest.mean, 0)), which is \(signed(offset)) % away from the centre (\(fmt(axis.mid, 0))). Games see that as constant input."))
            }

            r.settleCount = m.settles.count
            r.settleFromLow = mean(m.settles.filter { $0.from == .low }.map(\.value))
            r.settleFromHigh = mean(m.settles.filter { $0.from == .high }.map(\.value))
            let values = m.settles.map(\.value)
            if let lowest = values.min(), let highest = values.max() {
                let spread = 100 * (highest - lowest) / axis.halfRange
                r.settleSpreadPercent = spread
                let spreadGrade = grade(spread, s.spreadMarginal, s.spreadBad)
                if spreadGrade > .ok {
                    findings.append(Finding(spreadGrade, "Comes back to anywhere between \(fmt(lowest, 0)) and \(fmt(highest, 0)) after release (\(fmt(spread)) % spread). That is mechanical; recalibrating will not remove it, a dead zone hides it."))
                }
            } else {
                findings.append(Finding(.ok, "No release was captured, so the dead zone is based on the rest step only."))
            }

            // Smallest dead zone around the nominal centre that covers every resting place seen.
            let restingPlaces = [Double(m.rest.low), Double(m.rest.high)] + values
            let needed = 100 * (restingPlaces.map { abs($0 - axis.mid) }.max() ?? 0) / axis.halfRange
            let deadzone = needed < 0.1 ? 0 : (needed * s.deadzoneMargin / s.deadzoneStep).rounded(.up) * s.deadzoneStep
            if offsetGrade == .bad {
                // A dead zone wide enough to swallow this would swallow most of the travel too.
                r.needsRecalibrationNotDeadzone = true
            } else {
                r.suggestedDeadzonePercent = deadzone
            }
        }

        if findings.allSatisfy({ $0.severity == .ok }) {
            findings.insert(Finding(.ok, axis.kind == .centring
                ? "Centre, range and jitter are within tolerance."
                : "Range and jitter are within tolerance."), at: 0)
        }
        r.findings = findings
        r.severity = findings.map(\.severity).max() ?? .ok
        return r
    }

    static func grade(_ value: Double, _ marginal: Double, _ bad: Double) -> Severity {
        value >= bad ? .bad : value >= marginal ? .marginal : .ok
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

func fmt(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value)
}

func signed(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%+.\(digits)f", value)
}

extension Report {
    /// The report as Markdown, for pasting into notes or a support request.
    public func markdown(title: String, subtitle: String) -> String {
        var lines = ["# Stick check: \(title)", "", subtitle, ""]
        lines.append("Overall: **\(overall?.label ?? "Not tested")**")
        lines.append("")
        lines.append("| Axis | Type | Verdict | Rest (raw) | Centre offset | Jitter | Range reached | Return spread | Dead zone |")
        lines.append("|---|---|---|---|---|---|---|---|---|")
        for r in axes {
            let dash = "–"
            let cells = [
                r.axis.name,
                r.axis.kind == .centring ? "self-centring" : "slider",
                r.verdict,
                r.restValue.map { fmt($0, 0) } ?? dash,
                r.centreOffsetPercent.map { "\(signed($0, 2)) %" } ?? dash,
                r.noiseCounts.map { "\($0) counts" } ?? dash,
                r.rangeLow.flatMap { low in r.rangeHigh.map { "\(low)…\($0) of \(r.axis.logicalMin)…\(r.axis.logicalMax)" } } ?? dash,
                r.settleSpreadPercent.map { "\(fmt($0, 2)) % (\(r.settleCount) releases)" } ?? dash,
                r.needsRecalibrationNotDeadzone ? "not a fix: recalibrate"
                    : r.suggestedDeadzonePercent.map { $0 == 0 ? "none" : "\(fmt($0)) %" } ?? dash,
            ]
            lines.append("| " + cells.joined(separator: " | ") + " |")
        }
        lines.append("")
        lines.append("## Findings")
        lines.append("")
        for r in axes where r.tested {
            for finding in r.findings {
                lines.append("- **\(r.axis.name)** (\(finding.severity.label)): \(finding.text)")
            }
        }
        let untested = axes.filter { !$0.tested }.map(\.axis.name)
        if !untested.isEmpty {
            lines.append("- Not moved, so not judged: \(untested.joined(separator: ", ")).")
        }
        if restDisturbed {
            lines.append("- The stick moved during the rest step, so that measurement was started over.")
        }
        lines.append("")
        lines.append("Centre offset and return spread are % of half the range; jitter and range are % of the full range. Raw values are the counts the stick reports over USB, before any game settings.")
        return lines.joined(separator: "\n") + "\n"
    }
}
