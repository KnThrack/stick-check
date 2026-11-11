import Testing
@testable import StickCore

/// Drives a session with synthetic frames at 60 Hz.
struct Sim {
    var session: Session
    var time = 0.0
    var current: [Int]

    init(axes: [AxisInfo], start: [Int]) {
        session = Session(axes: axes)
        current = start
    }

    mutating func hold(_ seconds: Double) {
        for _ in 0..<Int((seconds * 60).rounded()) { step(current) }
    }

    mutating func move(axis: Int, to target: Int, over seconds: Double = 0.3) {
        let from = current[axis]
        let steps = max(1, Int((seconds * 60).rounded()))
        for i in 1...steps {
            var values = current
            values[axis] = from + (target - from) * i / steps
            step(values)
        }
    }

    mutating func step(_ values: [Int]) {
        let samples = zip(current, values).map { AxisSample(value: $1, low: min($0, $1), high: max($0, $1)) }
        current = values
        time += 1.0 / 60
        session.apply(.frame(Frame(time: time, samples: samples)))
    }

    /// Push to one end, hold, let go so it comes back to `restingAt`, wait.
    mutating func flick(axis: Int, to end: Int, restingAt: Int) {
        move(axis: axis, to: end)
        hold(0.3)
        move(axis: axis, to: restingAt, over: 0.1)
        hold(1.0)
    }
}

let stickX = AxisInfo(id: 0, name: "X", logicalMin: 0, logicalMax: 4095, kind: .centring)
let throttle = AxisInfo(id: 1, name: "Z", logicalMin: 0, logicalMax: 2047, kind: .slider)

/// Runs the whole test on X (+ a throttle) with the given behaviour and returns the report.
func runTest(rest: Int = 2048, low: Int = 0, high: Int = 4095, backFromLow: Int? = nil, backFromHigh: Int? = nil) -> Report {
    var sim = Sim(axes: [stickX, throttle], start: [rest, 500])
    sim.session.apply(.start)
    sim.hold(3.2)
    #expect(sim.session.phase == .range)
    sim.move(axis: 0, to: low)
    sim.move(axis: 0, to: high)
    sim.move(axis: 0, to: rest)
    sim.move(axis: 1, to: 0)
    sim.move(axis: 1, to: 2047)
    sim.session.apply(.next)
    #expect(sim.session.phase == .recentre)
    for _ in 0..<3 {
        sim.flick(axis: 0, to: low, restingAt: backFromLow ?? rest)
        sim.flick(axis: 0, to: high, restingAt: backFromHigh ?? rest)
    }
    sim.session.apply(.next)
    #expect(sim.session.phase == .done)
    return Analysis.report(for: sim.session)
}

@Test func healthyStickPasses() {
    let report = runTest()
    let x = report.axes[0]
    #expect(x.tested)
    #expect(x.severity == .ok)
    #expect(abs(x.centreOffsetPercent ?? 99) < 0.1)
    #expect(x.settleCount == 6)
    #expect(x.suggestedDeadzonePercent == 0)
    #expect(report.axes[1].severity == .ok)
    #expect(report.overall == .ok)
}

@Test func offCentreRestNeedsRecalibration() {
    // 2248 on a 0…4095 axis is 200.5 counts from 2047.5: 9.8 % of half the range.
    let x = runTest(rest: 2248).axes[0]
    #expect(x.severity == .bad)
    #expect(abs((x.centreOffsetPercent ?? 0) - 9.79) < 0.05)
    // 9.79 % × 1.25 margin, rounded up to the next 0.5.
    #expect(x.suggestedDeadzonePercent == 12.5)
}

@Test func shortTravelIsReported() {
    let x = runTest(low: 100).axes[0]
    #expect(abs((x.lowShortfallPercent ?? 0) - 2.44) < 0.01)
    #expect(x.highShortfallPercent == 0)
    #expect(x.severity == .bad)
}

@Test func releasesAreRecordedPerSide() {
    let x = runTest(backFromLow: 2030, backFromHigh: 2066).axes[0]
    #expect(x.settleCount == 6)
    #expect(x.settleFromLow == 2030)
    #expect(x.settleFromHigh == 2066)
    // 36 counts of 2047.5 = 1.76 %: marginal, not bad.
    #expect(abs((x.settleSpreadPercent ?? 0) - 1.76) < 0.01)
    #expect(x.severity == .marginal)
    // Furthest resting place is 18.5 counts out: 0.90 % × 1.25 → 1.5 %.
    #expect(x.suggestedDeadzonePercent == 1.5)
}

@Test func holdingAtTheLimitIsNotARelease() {
    var sim = Sim(axes: [stickX], start: [2048])
    sim.session.apply(.start)
    sim.hold(3.2)
    sim.move(axis: 0, to: 0)
    sim.move(axis: 0, to: 4095)
    sim.move(axis: 0, to: 2048)
    sim.session.apply(.next)
    sim.move(axis: 0, to: 4095)
    sim.hold(3)
    #expect(sim.session.measurements[0].settles.isEmpty)
    // Resting in the middle without having been deflected is not a release either.
    sim.move(axis: 0, to: 2048, over: 0.1)
    sim.hold(1)
    sim.hold(2)
    #expect(sim.session.measurements[0].settles.count == 1)
}

@Test func movementDuringRestRestartsIt() {
    var sim = Sim(axes: [stickX], start: [2048])
    sim.session.apply(.start)
    sim.hold(2)
    sim.move(axis: 0, to: 3000)
    sim.move(axis: 0, to: 2048)
    #expect(sim.session.restDisturbed)
    #expect(sim.session.phase == .rest)
    sim.hold(3.2)
    #expect(sim.session.phase == .range)
    #expect(sim.session.measurements[0].rest.peakToPeak == 0)
}

@Test func restGivesUpOnAStickThatNeverHoldsStill() {
    var sim = Sim(axes: [stickX], start: [2048])
    sim.session.apply(.start)
    for _ in 0..<40 {
        sim.move(axis: 0, to: 2300)
        sim.move(axis: 0, to: 1800)
    }
    #expect(sim.session.phase != .rest)
    #expect(sim.session.restDisturbed)
}

@Test func unmovedAxisIsNotJudged() {
    var sim = Sim(axes: [stickX, throttle], start: [2048, 0])
    sim.session.apply(.start)
    sim.hold(3.2)
    sim.move(axis: 0, to: 0)
    sim.move(axis: 0, to: 4095)
    sim.session.apply(.next)
    sim.session.apply(.next)
    let report = Analysis.report(for: sim.session)
    #expect(report.axes[0].tested)
    #expect(!report.axes[1].tested)
    #expect(report.axes[1].verdict == "Not tested")
}

@Test func kindCannotChangeMidTest() {
    var session = Session(axes: [stickX])
    session.apply(.setKind(axis: 0, kind: .slider))
    #expect(session.axes[0].kind == .slider)
    session.apply(.start)
    session.apply(.setKind(axis: 0, kind: .centring))
    #expect(session.axes[0].kind == .slider)
    session.apply(.setKind(axis: 7, kind: .centring))
}

@Test func markdownListsEveryAxis() {
    let text = runTest(rest: 2248).markdown(title: "Test stick", subtitle: "11-11-2026 22:13")
    #expect(text.contains("# Stick check: Test stick"))
    #expect(text.contains("| X | self-centring | Needs recalibration |"))
    #expect(text.contains("| Z | slider | OK |"))
}

@Test func axisNamesFollowHIDUsages() {
    #expect(AxisInfo.describe(usagePage: 1, usage: 0x35, ordinal: 3).name == "Rz")
    #expect(AxisInfo.describe(usagePage: 1, usage: 0x32, ordinal: 4).kind == .slider)
    #expect(AxisInfo.describe(usagePage: 0, usage: 0, ordinal: 7).name == "Axis 7")
}

// MARK: - Randomised playouts

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Test(arguments: 0..<40)
func randomPlayoutsKeepInvariants(seed: Int) {
    var rng = SplitMix64(state: UInt64(seed) &* 7919 &+ 1)
    let axes = [stickX, throttle, AxisInfo(id: 2, name: "Rz", logicalMin: 0, logicalMax: 2047, kind: .centring)]
    var session = Session(axes: axes)
    var time = 0.0
    var values = axes.map { Int($0.mid) }

    for _ in 0..<1500 {
        let before = session.phase
        let roll = Int.random(in: 0..<100, using: &rng)
        let command: Command
        switch roll {
        case 0: command = .start
        case 1, 2: command = .next
        case 3: command = .cancel
        case 4: command = .setKind(axis: Int.random(in: -1...3, using: &rng), kind: Bool.random(using: &rng) ? .centring : .slider)
        case 5: command = .frame(Frame(time: time, samples: [AxisSample(0)]))  // wrong axis count
        default:
            time += Double.random(in: 0...0.05, using: &rng)
            var samples: [AxisSample] = []
            for index in axes.indices {
                // Mostly small steps, sometimes a jump, sometimes a snap back to the centre.
                let jump = Int.random(in: 0..<10, using: &rng)
                let target: Int
                switch jump {
                case 0: target = Int.random(in: axes[index].logicalMin...axes[index].logicalMax, using: &rng)
                case 1, 2, 3: target = Int(axes[index].mid) + Int.random(in: -3...3, using: &rng)
                default: target = values[index] + Int.random(in: -2...2, using: &rng)
                }
                let next = min(axes[index].logicalMax, max(axes[index].logicalMin, target))
                samples.append(AxisSample(value: next, low: min(values[index], next), high: max(values[index], next)))
                values[index] = next
            }
            command = .frame(Frame(time: time, samples: samples))
        }
        session.apply(command)

        // Only legal transitions.
        let after = session.phase
        if before != after {
            let legal: [Phase: Set<Phase>] = [
                .idle: [.rest], .rest: [.range, .idle], .range: [.recentre, .idle, .rest],
                .recentre: [.done, .idle, .rest], .done: [.rest],
            ]
            #expect(legal[before]?.contains(after) == true, "\(before) → \(after) on \(command)")
        }
        #expect(session.measurements.count == axes.count)
        #expect(session.phaseElapsed >= 0)
        for (axis, m) in zip(session.axes, session.measurements) {
            if let low = m.rangeLow, let high = m.rangeHigh {
                #expect(low <= high)
                #expect(low >= axis.logicalMin && high <= axis.logicalMax)
            }
            for settle in m.settles {
                #expect(settle.value >= Double(axis.logicalMin) && settle.value <= Double(axis.logicalMax))
            }
            if axis.kind == .slider, session.isRunning { #expect(m.deflected == nil) }
        }

        // The analysis must hold up at any moment, not only when the test is done.
        let report = Analysis.report(for: session)
        for r in report.axes {
            for number in [r.centreOffsetPercent, r.noisePercent, r.lowShortfallPercent, r.highShortfallPercent,
                           r.settleSpreadPercent, r.suggestedDeadzonePercent].compactMap({ $0 }) {
                #expect(number.isFinite)
            }
            #expect((r.suggestedDeadzonePercent ?? 0) >= 0)
            #expect((r.lowShortfallPercent ?? 0) >= 0 && (r.highShortfallPercent ?? 0) >= 0)
            #expect(!r.findings.isEmpty)
            #expect(r.severity == (r.findings.map(\.severity).max() ?? .ok))
        }
        #expect(!report.markdown(title: "t", subtitle: "s").isEmpty)
    }
}
