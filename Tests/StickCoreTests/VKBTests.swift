import Testing
@testable import StickCore

/// A simulated stick that speaks the documented protocol, including its stale-reply quirk.
final class MockStick: FeatureTransport {
    let token: [UInt8]
    var block: [UInt8]
    var sent: [[UInt8]] = []
    var replies: [[UInt8]] = []
    var staleNext = false
    var corruptReplies = false
    var silent = false

    init(token: [UInt8], block: [UInt8]) {
        self.token = token
        self.block = block
    }

    func send(_ frame: [UInt8]) throws {
        sent.append(frame)
        replies = []
        guard !silent, frame.count == 128, frame[0] == 0xA5, frame[1] & 0xC0 == 0xC0 else { return }
        if staleNext {
            staleNext = false
            replies = [[0x5A, 0x4B] + [UInt8](repeating: 0, count: 126)]
            return
        }
        let size = Int(frame[2]) | Int(frame[3]) << 8
        var data: [UInt8]
        switch frame[1] & 0x3F {
        case 0x0B:
            data = [UInt8](repeating: 0xEE, count: 0x78)
            data.replaceSubrange(0x58..<0x68, with: VKBBytes.rc4(token, key: VKBLink.cpuidKey))
            staleNext = true
        case 0x02, 0x03:
            data = Array(VKBBytes.rc4(block, key: Array(token.prefix(15))).prefix(size))
        default:
            return
        }
        let crc = VKBBytes.crc16Modbus(data)
        if corruptReplies { data[data.count / 2] ^= 0x01 }
        var first: [UInt8] = [0x5A, frame[1], frame[2], frame[3], frame[4], frame[5], UInt8(crc & 0xFF), UInt8(crc >> 8)]
        first += data.prefix(120)
        replies.append(first + [UInt8](repeating: 0, count: 128 - first.count))
        var offset = 120
        while offset < data.count {
            let chunk = Array(data[offset..<min(offset + 128, data.count)])
            replies.append(chunk + [UInt8](repeating: 0, count: 128 - chunk.count))
            offset += 128
        }
    }

    func receive() throws -> [UInt8] {
        replies.isEmpty ? [UInt8](repeating: 0, count: 128) : replies.removeFirst()
    }

    func pause(milliseconds: Int) {}
}

/// A plausible block: header, firmware 2.20.C, three calibrated axes, the rest at defaults.
func sampleBlock() -> [UInt8] {
    var block = [UInt8](repeating: 0, count: 0x1000)
    block.replaceSubrange(0..<4, with: [0xFF, 0xFF, 0x11, 0xFF])
    block[8] = 0x0C
    block[9] = 0x22
    block[0x0C] = 0b0000_0111
    for slot in 0..<8 {
        let base = 0x7C + 8 * slot
        block[base + 4] = 255
        block[base + 5] = 255
    }
    // Slot 0: gains 120/131, bias +37. Slot 1: bias −5 (0x1FFB in 13 bits), inverted. Slot 2: auto-centre.
    block.replaceSubrange(0x7C..<0x84, with: [0x00, 0, 0, 0, 120, 131, 37, 0])
    block.replaceSubrange(0x84..<0x8C, with: [0x04, 0, 0, 0, 99, 101, 0xFB, 0x1F])
    block.replaceSubrange(0x8C..<0x94, with: [0x01, 0, 0, 0, 200, 201, 0x00, 0x10])
    // Output axes: X reads slot 0; Rz reads slot 2 at 11 bits with a 1.5 % centre dead zone, inverted;
    // a hidden Slider on slot 1; Y is the second half of a circular dead zone with X; the rest disabled.
    block.replaceSubrange(0x3C..<0x44, with: [0xB0, 0x00, 0x0C, 0, 0, 0, 0, 0])
    block.replaceSubrange(0x44..<0x4C, with: [0xF2, 0x05, 0x0B, 15, 20, 0, 0, 0])
    block.replaceSubrange(0x4C..<0x54, with: [0x11, 0x06, 0x0C, 0, 0, 0, 0, 0])
    block.replaceSubrange(0x54..<0x5C, with: [0xB1, 0x41, 0x0C, 0x00, 0, 0, 0, 0])
    let crc = VKBBytes.crc32STM32(block[8...])
    for i in 0..<4 { block[4 + i] = UInt8((crc >> (8 * UInt32(i))) & 0xFF) }
    return block
}

let sampleToken: [UInt8] = (1...16).map { UInt8($0 * 13 & 0xFF) }

@Test func checksumAndCipherMatchPublishedVectors() {
    #expect(VKBBytes.crc16Modbus(Array("123456789".utf8)) == 0x4B37)
    #expect(VKBBytes.crc32STM32([0x78, 0x56, 0x34, 0x12][...]) == 0xDF8A_8A2B)
    #expect(VKBBytes.crc32STM32(Array(0..<12)[...]) == 0xEAD5_6648)
    #expect(VKBBytes.rc4(Array("Plaintext".utf8), key: Array("Key".utf8))
        == [0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3])
    let secret = Array("round trip".utf8)
    #expect(VKBBytes.rc4(VKBBytes.rc4(secret, key: [1, 2, 3]), key: [1, 2, 3]) == secret)
}

@Test func readsTokenAndBlockFromTheStick() throws {
    let stick = MockStick(token: sampleToken, block: sampleBlock())
    var link = VKBLink(transport: stick)
    let token = try link.readToken()
    #expect(token == sampleToken)
    let block = try link.readBlock(token: token)
    #expect(block.bytes == sampleBlock())
    #expect(block.isIntact)
    // The request after READ_CPUID gets a stale frame and has to be repeated once.
    #expect(link.retries == 1)
    #expect(try link.readBlock(token: token, from: .readRAM).bytes == sampleBlock())
}

@Test func onlyReadRequestsAreEverSent() throws {
    let stick = MockStick(token: sampleToken, block: sampleBlock())
    var link = VKBLink(transport: stick)
    let token = try link.readToken()
    _ = try link.readBlock(token: token)
    _ = try link.readBlock(token: token, from: .readRAM)
    #expect(!stick.sent.isEmpty)
    for frame in stick.sent {
        #expect(frame.count == 128)
        #expect(frame[0] == 0xA5)
        // 0xCB read CPUID, 0xC2 read flash, 0xC3 read RAM. Never a write (0x80 flag alone) or a short command (0x5A).
        #expect([0xCB, 0xC2, 0xC3].contains(frame[1]))
        #expect(frame[6] == 0 && frame[7] == 0)
        #expect(frame[8...].allSatisfy { $0 == 0 })
    }
    for command in VKBReadCommand.allCases {
        let frame = VKBLink.readRequest(command, size: 0x1000, address: 0)
        #expect(frame[1] & 0xC0 == 0xC0)
        #expect(frame[1] != 0x5A)
    }
}

@Test func damagedTransferIsRefused() throws {
    let stick = MockStick(token: sampleToken, block: sampleBlock())
    var link = VKBLink(transport: stick)
    let token = try link.readToken()
    stick.corruptReplies = true
    #expect(throws: VKBError.damagedTransfer) { try link.readBlock(token: token) }
}

@Test func silentStickGivesUp() {
    let stick = MockStick(token: sampleToken, block: sampleBlock())
    stick.silent = true
    var link = VKBLink(transport: stick)
    #expect(throws: VKBError.noAnswer) { try link.readToken() }
    #expect(stick.sent.count == 4)
}

@Test func wrongTokenShowsAsChecksumMismatch() throws {
    let stick = MockStick(token: sampleToken, block: sampleBlock())
    var link = VKBLink(transport: stick)
    var token = try link.readToken()
    token[3] ^= 0xFF
    #expect(try !link.readBlock(token: token).isIntact)
}

@Test func blockDecodesHeaderAndCalibration() throws {
    let block = try VKBBlock(bytes: sampleBlock())
    #expect(block.typeID == 0x11)
    #expect(block.firmwareText == "2.20.C")
    #expect(block.isIntact)
    let axes = block.physicalAxes
    #expect(axes.count == 8)
    #expect(axes[0].kdHi == 120 && axes[0].kdLo == 131 && axes[0].bias == 37)
    #expect(axes[0].calibrated && !axes[0].inverted)
    #expect(axes[1].bias == -5 && axes[1].inverted)
    #expect(axes[2].bias == -4096 && axes[2].autoCentring)
    #expect(!axes[3].calibrated && !axes[3].holdsCalibration)
    #expect(block.summary.contains("firmware 2.20.C"))

    var damaged = sampleBlock()
    damaged[0x200] ^= 0x40
    #expect(try !VKBBlock(bytes: damaged).isIntact)
    #expect(throws: VKBError.wrongBlockSize(100)) { try VKBBlock(bytes: [UInt8](repeating: 0, count: 100)) }
}

@Test func blockDecodesOutputAxesAndTheirSensors() throws {
    let block = try VKBBlock(bytes: sampleBlock())
    let axes = block.logicalAxes
    #expect(axes[0].usageName == "X" && axes[0].physicalSlot == 0 && axes[0].precisionBits == 12)
    #expect(axes[0].enabled && axes[0].visible && axes[0].centred && !axes[0].inverted)
    #expect(axes[1].usageName == "Rz" && axes[1].physicalSlot == 2 && axes[1].precisionBits == 11)
    #expect(axes[1].inverted && axes[1].deadzoneLow == 1.5 && axes[1].deadzoneHigh == 2.0)
    #expect(axes[2].usageName == "Slider" && !axes[2].visible && !axes[2].centred)
    #expect(axes[3].usageName == "Y" && axes[3].deadzoneLow == nil && axes[3].circularDeadzonePartner == 0)
    #expect(!axes[4].enabled)

    // Looking an axis up by the name the live view uses gives the sensor slot behind it.
    let twist = try #require(block.storedAxis(named: "Rz"))
    #expect(twist.physical.slot == 2 && twist.physical.bias == -4096)
    #expect(block.storedAxis(named: "X")?.physical.bias == 37)
    #expect(block.storedAxis(named: "Slider") == nil)   // hidden
    #expect(block.storedAxis(named: "Z") == nil)        // not configured
    #expect(block.summary.contains("Rz      ← slot 2, 11 bit, dead zone 1.5 % low / 2.0 % high, centred, inverted"))
}
