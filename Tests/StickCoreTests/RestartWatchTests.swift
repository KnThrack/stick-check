import Testing
@testable import StickCore

@Test func stickThatRestartsIsReadAfterItSettles() {
    var watch = RestartWatch(oldDevice: 7, started: 100)
    #expect(watch.check(now: 100.1, device: 7) == .wait)
    #expect(watch.check(now: 100.4, device: nil) == .wait)      // left the bus
    #expect(watch.check(now: 102.8, device: 9) == .wait)        // back as a new device, still starting up
    #expect(watch.check(now: 103.5, device: 9) == .wait)
    #expect(watch.check(now: 103.8, device: 9) == .ready(restarted: true))
}

@Test func stickThatStaysConnectedIsReadAfterTheTimeout() {
    var watch = RestartWatch(oldDevice: 7, started: 100)
    #expect(watch.check(now: 104, device: 7) == .wait)
    #expect(watch.check(now: 107.9, device: 7) == .wait)
    #expect(watch.check(now: 108, device: 7) == .ready(restarted: false))
}

@Test func stickThatComesBackUnderItsOldIDStillCountsAsRestarted() {
    var watch = RestartWatch(oldDevice: 7, started: 100)
    #expect(watch.check(now: 100.5, device: nil) == .wait)
    #expect(watch.check(now: 102, device: 7) == .wait)
    #expect(watch.check(now: 103, device: 7) == .ready(restarted: true))
}

@Test func stickThatDropsOutAgainRestartsTheSettlePause() {
    var watch = RestartWatch(oldDevice: 7, started: 100)
    #expect(watch.check(now: 101, device: nil) == .wait)
    #expect(watch.check(now: 102, device: 9) == .wait)
    #expect(watch.check(now: 102.5, device: nil) == .wait)
    #expect(watch.check(now: 103, device: 9) == .wait)
    #expect(watch.check(now: 103.9, device: 9) == .wait)
    #expect(watch.check(now: 104, device: 9) == .ready(restarted: true))
}

@Test func stickThatNeverComesBackIsReportedLost() {
    var watch = RestartWatch(oldDevice: 7, started: 100)
    #expect(watch.check(now: 101, device: nil) == .wait)
    #expect(watch.check(now: 119.9, device: nil) == .wait)
    #expect(watch.check(now: 120, device: nil) == .lost)
}
