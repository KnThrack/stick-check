/// Whether an axis springs back to a centre (stick, twist, ministick) or stays where it is put (throttle, dial).
public enum AxisKind: String, Sendable, Codable, CaseIterable {
    case centring
    case slider
}

/// One analogue axis as the device describes it. Values are raw logical counts.
public struct AxisInfo: Sendable, Equatable, Identifiable {
    public let id: Int
    public var name: String
    public var logicalMin: Int
    public var logicalMax: Int
    public var kind: AxisKind

    public init(id: Int, name: String, logicalMin: Int, logicalMax: Int, kind: AxisKind) {
        self.id = id
        self.name = name
        self.logicalMin = logicalMin
        self.logicalMax = logicalMax
        self.kind = kind
    }

    public var span: Double { Double(logicalMax - logicalMin) }
    public var halfRange: Double { span / 2 }
    /// Nominal centre: the value a game treats as "no input".
    public var mid: Double { Double(logicalMin + logicalMax) / 2 }

    /// Position as 0…1 of the logical range.
    public func fraction(_ value: Double) -> Double {
        span > 0 ? min(1, max(0, (value - Double(logicalMin)) / span)) : 0
    }

    /// Name and default kind for a HID usage. `ordinal` is the 1-based position among the device's axes.
    public static func describe(usagePage: Int, usage: Int, ordinal: Int) -> (name: String, kind: AxisKind) {
        guard usagePage == 0x01 else { return ("Axis \(ordinal)", .slider) }
        switch usage {
        case 0x30: return ("X", .centring)
        case 0x31: return ("Y", .centring)
        case 0x32: return ("Z", .slider)
        case 0x33: return ("Rx", .centring)
        case 0x34: return ("Ry", .centring)
        case 0x35: return ("Rz", .centring)
        case 0x36: return ("Slider", .slider)
        case 0x37: return ("Dial", .slider)
        case 0x38: return ("Wheel", .slider)
        default: return ("Axis \(ordinal)", .slider)
        }
    }
}

/// An axis reading for one frame: the latest value plus the extremes seen since the previous frame,
/// so fast movements between frames are not lost.
public struct AxisSample: Sendable, Equatable {
    public var value: Int
    public var low: Int
    public var high: Int

    public init(value: Int, low: Int, high: Int) {
        self.value = value
        self.low = low
        self.high = high
    }

    public init(_ value: Int) {
        self.init(value: value, low: value, high: value)
    }
}

/// All axes at one moment. `samples` is in the same order as the session's axes.
public struct Frame: Sendable, Equatable {
    public var time: Double
    public var samples: [AxisSample]

    public init(time: Double, samples: [AxisSample]) {
        self.time = time
        self.samples = samples
    }
}
