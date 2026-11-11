/// Steps of the guided test.
public enum Phase: String, Sendable, Equatable {
    /// Nothing running.
    case idle
    /// Hands off: measure where each axis rests and how much it jitters.
    case rest
    /// Move every axis to its limits: measure the range that is reported.
    case range
    /// Deflect and release: measure where self-centring axes come back to.
    case recentre
    /// Finished; the measurements are ready to be analysed.
    case done
}

public enum Side: String, Sendable, Equatable {
    case low
    case high
}

/// Where a self-centring axis came to rest after being released from one side.
public struct Settle: Sendable, Equatable {
    public var value: Double
    public var from: Side
}

public struct RestStats: Sendable, Equatable {
    public private(set) var count = 0
    public private(set) var sum = 0.0
    public private(set) var low = Int.max
    public private(set) var high = Int.min

    mutating func add(_ sample: AxisSample) {
        count += 1
        sum += Double(sample.value)
        low = min(low, sample.low)
        high = max(high, sample.high)
    }

    public var mean: Double { count > 0 ? sum / Double(count) : 0 }
    public var peakToPeak: Int { count > 0 ? high - low : 0 }
}

public struct AxisMeasurement: Sendable, Equatable {
    public internal(set) var rest = RestStats()
    public internal(set) var rangeLow: Int?
    public internal(set) var rangeHigh: Int?
    public internal(set) var settles: [Settle] = []

    // Release detector state.
    var deflected: Side?
    var windowStart: Double?
    var windowLow = 0
    var windowHigh = 0

    public func settleCount(from side: Side) -> Int {
        settles.count { $0.from == side }
    }
}

public struct Settings: Sendable, Equatable {
    /// Seconds of stillness measured in the rest step.
    public var restDuration = 3.0
    /// Movement during the rest step above this share of the range restarts the measurement.
    public var restDisturbanceFraction = 0.02
    /// After this many seconds without a still stretch, the rest step stops restarting and takes what it gets.
    public var restGiveUpAfter = 20.0
    /// An axis that travelled less than this share of its range was not exercised.
    public var minTravelFraction = 0.05
    /// Share of the travel on one side that counts as "deflected".
    public var deflectFraction = 0.5
    /// Share of the travel on one side that still counts as "back near the centre".
    public var nearCentreFraction = 0.25
    /// Seconds an axis must hold still before its resting place is recorded.
    public var settleTime = 0.5
    public var stableBandFraction = 0.004
    public var stableBandCounts = 4.0

    // Verdict thresholds (marginal, needs recalibration).
    /// Rest position away from the nominal centre, % of half the range.
    public var centreOffsetMarginal = 1.0
    public var centreOffsetBad = 3.0
    /// Travel that is never reported at one end, % of the range.
    public var shortfallMarginal = 0.5
    public var shortfallBad = 2.0
    /// Peak-to-peak jitter at rest, % of the range.
    public var noiseMarginal = 0.3
    public var noiseBad = 1.0
    /// Spread of the resting places after release, % of half the range.
    public var spreadMarginal = 1.0
    public var spreadBad = 3.0

    public var deadzoneMargin = 1.25
    public var deadzoneStep = 0.5

    public init() {}
}

/// Everything that can happen to a session. The UI only ever sends these.
public enum Command: Sendable, Equatable {
    case start
    case next
    case cancel
    case setKind(axis: Int, kind: AxisKind)
    case frame(Frame)
}

/// The guided test as a state machine. Pure: feed it commands, read its state.
public struct Session: Sendable, Equatable {
    public private(set) var axes: [AxisInfo]
    public private(set) var phase: Phase = .idle
    public private(set) var measurements: [AxisMeasurement]
    /// True when the stick moved during the rest step and the measurement had to start over.
    public private(set) var restDisturbed = false
    private var restBegan: Double?
    public private(set) var phaseStart: Double?
    public private(set) var lastTime: Double?
    public var settings: Settings

    public init(axes: [AxisInfo], settings: Settings = Settings()) {
        self.axes = axes
        self.settings = settings
        self.measurements = Array(repeating: AxisMeasurement(), count: axes.count)
    }

    public var isRunning: Bool { phase == .rest || phase == .range || phase == .recentre }

    public var phaseElapsed: Double {
        guard let phaseStart, let lastTime else { return 0 }
        return lastTime - phaseStart
    }

    public var restRemaining: Double { max(0, settings.restDuration - phaseElapsed) }

    public mutating func apply(_ command: Command) {
        switch command {
        case .start:
            measurements = Array(repeating: AxisMeasurement(), count: axes.count)
            restDisturbed = false
            restBegan = nil
            enter(.rest)
        case .next:
            switch phase {
            case .range: enter(.recentre)
            case .recentre: enter(.done)
            case .idle, .rest, .done: break
            }
        case .cancel:
            if isRunning { enter(.idle) }
        case .setKind(let axis, let kind):
            // Changing what an axis is mid-test would mix measurements taken under different rules.
            guard !isRunning, axes.indices.contains(axis) else { return }
            axes[axis].kind = kind
        case .frame(let frame):
            ingest(frame)
        }
    }

    private mutating func enter(_ newPhase: Phase) {
        phase = newPhase
        phaseStart = nil
        lastTime = nil
        for index in measurements.indices {
            measurements[index].deflected = nil
            measurements[index].windowStart = nil
        }
    }

    private mutating func ingest(_ frame: Frame) {
        guard isRunning, frame.samples.count == axes.count else { return }
        if let lastTime, frame.time < lastTime { return }
        if phaseStart == nil { phaseStart = frame.time }
        lastTime = frame.time

        switch phase {
        case .rest:
            for index in axes.indices { measurements[index].rest.add(frame.samples[index]) }
            let disturbed = axes.indices.contains { index in
                Double(measurements[index].rest.peakToPeak) > settings.restDisturbanceFraction * axes[index].span
            }
            let began = restBegan ?? frame.time
            restBegan = began
            if disturbed, frame.time - began < settings.restGiveUpAfter {
                restDisturbed = true
                for index in axes.indices { measurements[index].rest = RestStats() }
                phaseStart = frame.time
            } else if phaseElapsed >= settings.restDuration {
                enter(.range)
            }
        case .range:
            for index in axes.indices { widenRange(index, frame.samples[index]) }
        case .recentre:
            for index in axes.indices {
                widenRange(index, frame.samples[index])
                if axes[index].kind == .centring {
                    detectSettle(index, frame.samples[index], time: frame.time)
                }
            }
        case .idle, .done:
            break
        }
    }

    private mutating func widenRange(_ index: Int, _ sample: AxisSample) {
        measurements[index].rangeLow = min(measurements[index].rangeLow ?? sample.low, sample.low)
        measurements[index].rangeHigh = max(measurements[index].rangeHigh ?? sample.high, sample.high)
    }

    /// Records where an axis comes to rest after it was pushed well to one side and let go.
    private mutating func detectSettle(_ index: Int, _ sample: AxisSample, time: Double) {
        let axis = axes[index]
        var m = measurements[index]
        defer { measurements[index] = m }
        guard let rangeLow = m.rangeLow, let rangeHigh = m.rangeHigh else { return }

        let rest = m.rest.mean
        let minTravel = settings.minTravelFraction * axis.span
        let lowTravel = rest - Double(rangeLow)
        let highTravel = Double(rangeHigh) - rest

        if lowTravel >= minTravel, Double(sample.low) < rest - settings.deflectFraction * lowTravel {
            m.deflected = .low
        }
        if highTravel >= minTravel, Double(sample.high) > rest + settings.deflectFraction * highTravel {
            m.deflected = .high
        }

        // Track how long the axis has held still.
        let band = max(settings.stableBandCounts,
                       settings.stableBandFraction * axis.span,
                       2 * Double(m.rest.peakToPeak))
        let newLow = min(m.windowLow, sample.low)
        let newHigh = max(m.windowHigh, sample.high)
        if m.windowStart == nil || Double(newHigh - newLow) > band {
            m.windowStart = time
            m.windowLow = sample.value
            m.windowHigh = sample.value
        } else {
            m.windowLow = newLow
            m.windowHigh = newHigh
        }

        guard let side = m.deflected, let start = m.windowStart, time - start >= settings.settleTime else { return }
        let resting = Double(m.windowLow + m.windowHigh) / 2
        let travel = max(resting < rest ? lowTravel : highTravel, minTravel)
        guard abs(resting - rest) <= settings.nearCentreFraction * travel else { return }
        m.settles.append(Settle(value: resting, from: side))
        m.deflected = nil
    }
}
