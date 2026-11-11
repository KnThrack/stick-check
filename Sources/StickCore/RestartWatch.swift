/// Decides when a stick that was told to store something is ready to be read again.
///
/// After a calibration commit or a configuration write the stick usually leaves the bus and
/// comes back a few seconds later as a new device. Sometimes it stays connected. Pure: feed it
/// the clock and the currently connected device, and it says what to do.
public struct RestartWatch: Sendable, Equatable {
    public enum Verdict: Sendable, Equatable {
        case wait
        /// Read the stick now. `restarted` tells whether it came back as a new device.
        case ready(restarted: Bool)
        /// The stick left and did not come back.
        case lost
    }

    public let oldDevice: UInt64
    public let started: Double
    /// How long a stick that never leaves is given before it is read as it is.
    public var stayedTimeout = 8.0
    /// How long a stick that left is given to come back.
    public var lostTimeout = 20.0
    /// Pause after the stick reappears, so it has finished starting up.
    public var settle = 1.0

    private var sawItLeave = false
    private var reconnectedAt: Double?

    public init(oldDevice: UInt64, started: Double) {
        self.oldDevice = oldDevice
        self.started = started
    }

    /// `device` is the connected stick's ID, or nil while none is connected.
    public mutating func check(now: Double, device: UInt64?) -> Verdict {
        guard let device else {
            sawItLeave = true
            reconnectedAt = nil
            return now - started >= lostTimeout ? .lost : .wait
        }
        if device != oldDevice || sawItLeave {
            let since = reconnectedAt ?? now
            reconnectedAt = since
            return now - since >= settle ? .ready(restarted: true) : .wait
        }
        return now - started >= stayedTimeout ? .ready(restarted: false) : .wait
    }
}
