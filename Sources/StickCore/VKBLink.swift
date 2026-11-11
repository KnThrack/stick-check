/// One feature report (ID 0x59) each way. Frames are always 128 bytes, without the report ID.
public protocol FeatureTransport: AnyObject {
    func send(_ frame: [UInt8]) throws
    func receive() throws -> [UInt8]
    func pause(milliseconds: Int)
}

public enum VKBError: Error, Equatable, CustomStringConvertible {
    /// The stick kept answering with something other than the reply to the request.
    case noAnswer
    /// The data arrived but its CRC-16 does not match.
    case damagedTransfer
    case malformedFrame
    case wrongBlockSize(Int)
    /// The block to write fails its own checksum, so it is damaged or not a configuration block.
    case blockNotIntact
    /// The block to write is for another device type or firmware version.
    case blockForOtherDevice
    /// The stick no longer holds what the caller last read; look again before writing.
    case stickChanged

    public var description: String {
        switch self {
        case .noAnswer: "The stick did not answer the request."
        case .damagedTransfer: "The transfer arrived damaged (CRC-16 mismatch)."
        case .malformedFrame: "The stick returned a frame of the wrong size."
        case .wrongBlockSize(let size): "Expected a 4096-byte configuration block, got \(size) bytes."
        case .blockNotIntact: "The configuration to write fails its own checksum. Nothing was sent."
        case .blockForOtherDevice: "The configuration to write is for a different device type or firmware. Nothing was sent."
        case .stickChanged: "The stick's configuration is not what was read a moment ago. Nothing was sent."
        }
    }
}

/// The read requests this code can build. None changes anything on the stick.
public enum VKBReadCommand: UInt8, Sendable, CaseIterable {
    /// The configuration block stored in flash.
    case readFlash = 0x02
    /// The copy of the configuration block in RAM.
    case readRAM = 0x03
    /// The session token (the microcontroller's unique ID, lightly wrapped).
    case readCPUID = 0x0B
}

/// The two short commands this code can send. Both are known only from the vendor tool's binary.
///
/// The protocol's other short commands (restart, factory defaults, bootloader entry, and a
/// "cancel calibration" whose argument is not understood) are deliberately not representable.
public enum VKBCalibrationCommand: UInt8, Sendable, CaseIterable {
    /// The stick starts measuring the travel of its axes.
    case start = 0x02
    /// The stick works out the calibration from what it measured and stores it.
    case commit = 0x03
}

/// How a short command is put on the wire.
public enum VKBShortCommandForm: Sendable, CaseIterable {
    /// `A5 5A command argument`, the rest zero.
    case plain
    /// The same four bytes in the clear, the session token embedded, and the rest of the frame
    /// RC4-encrypted with those four bytes as the key. What the vendor tool sends to current
    /// sticks once it has read their configuration. Built from a one-sentence description, so
    /// the exact layout is the least certain part of this file.
    case encoded
}

/// The stick's answer to a block write.
public enum VKBWriteStatus: Equatable, Sendable, CustomStringConvertible {
    case written
    case noNewData
    case crcError
    case flashEraseError
    case flashWriteError
    case incompatibleProfile
    case unknown(UInt32)

    public init(word: UInt32) {
        switch word {
        case 0x0088_A55A: self = .written
        case 0x11A5_5A11: self = .noNewData
        case 0x2222_2222: self = .crcError
        case 0x31DE_AD31: self = .flashEraseError
        case 0x33DE_AD33: self = .flashWriteError
        case 0x33A5_5A33: self = .incompatibleProfile
        default: self = .unknown(word)
        }
    }

    public var description: String {
        switch self {
        case .written: "block written"
        case .noNewData: "no new data"
        case .crcError: "CRC error: the stick refused the transfer and wrote nothing"
        case .flashEraseError: "flash erase error"
        case .flashWriteError: "flash write error"
        case .incompatibleProfile: "non-compatible profile"
        case .unknown(let word): String(format: "unknown status %08X", word)
        }
    }
}

/// VKB's configuration protocol, as documented by the vkbdevcfg-explained project
/// (docs/PROTOCOL.md) and verified there on a Gladiator EVO R at firmware 2.20.C.
///
/// It can read, write a whole configuration block to flash behind the checks in `writeBlock`,
/// and send the two calibration commands in `VKBCalibrationCommand`. The protocol's other short
/// commands, which restart, reset or reflash the stick, are deliberately not representable here.
public struct VKBLink {
    public static let reportID: UInt8 = 0x59
    public static let frameSize = 128
    public static let blockSize = 0x1000
    static let headerSize = 8
    static let readFlag: UInt8 = 0xC0
    static let writeFlag: UInt8 = 0x80
    /// Long write of the configuration block to flash.
    static let writeFlashCommand: UInt8 = 0x24
    /// Fixed key from the vendor tool that unwraps the session token in the READ_CPUID reply.
    static let cpuidKey: [UInt8] = [0xF9, 0x14, 0x62, 0xA0, 0xD2, 0x6C, 0x8D, 0x4E, 0x88, 0xC6, 0xB0, 0x4C, 0x29]

    private let transport: any FeatureTransport
    /// How many times a request had to be repeated because the stick answered with a stale frame.
    public private(set) var retries = 0

    public init(transport: any FeatureTransport) {
        self.transport = transport
    }

    // MARK: - Reading

    /// The request frame for a long read: `A5 cmd|C0 size addr 0000`, zero-padded.
    public static func readRequest(_ command: VKBReadCommand, size: Int, address: Int) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: frameSize)
        frame[0] = 0xA5
        frame[1] = command.rawValue | readFlag
        frame[2] = UInt8(size & 0xFF)
        frame[3] = UInt8((size >> 8) & 0xFF)
        frame[4] = UInt8(address & 0xFF)
        frame[5] = UInt8((address >> 8) & 0xFF)
        return frame
    }

    private enum Attempt {
        case data([UInt8])
        case stale
    }

    private func longReadOnce(_ command: VKBReadCommand, size: Int, address: Int) throws -> Attempt {
        try transport.send(Self.readRequest(command, size: size, address: address))
        transport.pause(milliseconds: 9)
        var frame = try transport.receive()
        guard frame.count == Self.frameSize else { throw VKBError.malformedFrame }
        // The stick echoes the command and address; anything else is an answer to something earlier.
        guard frame[0] == 0x5A, frame[1] == command.rawValue | Self.readFlag,
              Int(frame[4]) | Int(frame[5]) << 8 == address
        else { return .stale }

        let want = min(size, Int(frame[2]) | Int(frame[3]) << 8)
        let crc = UInt16(frame[6]) | UInt16(frame[7]) << 8
        var data = Array(frame[Self.headerSize..<min(Self.frameSize, Self.headerSize + want)])
        // Always fetch every frame of the reply: a transfer left unfinished poisons the next request.
        while data.count < want {
            transport.pause(milliseconds: 5)
            frame = try transport.receive()
            guard frame.count == Self.frameSize else { throw VKBError.malformedFrame }
            data.append(contentsOf: frame[0..<min(Self.frameSize, want - data.count)])
        }
        guard VKBBytes.crc16Modbus(data) == crc else { throw VKBError.damagedTransfer }
        return .data(data)
    }

    /// Reads `size` bytes. The request after READ_CPUID is always answered with a stale frame, so
    /// the echo is checked and the request repeated.
    public mutating func longRead(_ command: VKBReadCommand, size: Int, address: Int = 0) throws -> [UInt8] {
        for _ in 0..<4 {
            switch try longReadOnce(command, size: size, address: address) {
            case .data(let data):
                return data
            case .stale:
                retries += 1
                transport.pause(milliseconds: 20)
            }
        }
        throw VKBError.noAnswer
    }

    /// The 16-byte session token. Its first 12 bytes are the microcontroller's unique ID, so treat
    /// it like a serial number: do not log or publish it.
    public mutating func readToken() throws -> [UInt8] {
        let reply = try longRead(.readCPUID, size: 0x78)
        guard reply.count >= 0x68 else { throw VKBError.malformedFrame }
        return VKBBytes.rc4(Array(reply[0x58..<0x68]), key: Self.cpuidKey)
    }

    /// The 4096-byte configuration block, decrypted.
    public mutating func readBlock(token: [UInt8], from command: VKBReadCommand = .readFlash) throws -> VKBBlock {
        let cipher = try longRead(command, size: Self.blockSize)
        return try VKBBlock(bytes: VKBBytes.rc4(cipher, key: Array(token.prefix(15))))
    }

    // MARK: - Calibration

    /// The frame for a calibration command, without the report ID.
    static func calibrationFrame(_ command: VKBCalibrationCommand, form: VKBShortCommandForm, token: [UInt8]) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: frameSize)
        frame[0] = 0xA5
        frame[1] = 0x5A
        frame[2] = command.rawValue
        frame[3] = 0x00
        guard form == .encoded else { return frame }
        // Offsets in the published description count from the report ID, which is not part of
        // `frame`: token at 0x58 there is 0x57 here, bytes 5…124 there are 4…123 here.
        frame.replaceSubrange(0x57..<0x67, with: token.prefix(16))
        frame.replaceSubrange(4..<124, with: VKBBytes.rc4(Array(frame[4..<124]), key: Array(frame[0..<4])))
        return frame
    }

    /// The first bytes of the stick's reply buffer, without asking it anything. The stick keeps
    /// returning its last reply, so this is the baseline an acknowledgement has to differ from.
    public func peekReply() throws -> [UInt8] {
        let frame = try transport.receive()
        guard frame.count >= 8 else { throw VKBError.malformedFrame }
        return Array(frame.prefix(8))
    }

    /// Sends a calibration command and returns the first bytes of whatever the stick answers
    /// (all zero when it has nothing to say).
    public func sendCalibration(_ command: VKBCalibrationCommand, form: VKBShortCommandForm, token: [UInt8]) throws -> [UInt8] {
        try transport.send(Self.calibrationFrame(command, form: form, token: token))
        var reply = [UInt8](repeating: 0, count: 8)
        for _ in 0..<5 {
            transport.pause(milliseconds: 10)
            let frame = try transport.receive()
            guard frame.count >= 8 else { throw VKBError.malformedFrame }
            reply = Array(frame.prefix(8))
            if reply.contains(where: { $0 != 0 }) { break }
        }
        return reply
    }

    // MARK: - Writing

    /// The frames of one long write to flash: an 8-byte header and 120 bytes of data, then 128
    /// bytes per frame, the last one zero-padded.
    static func writeFrames(data: [UInt8]) -> [[UInt8]] {
        let crc = VKBBytes.crc16Modbus(data)
        var frames: [[UInt8]] = []
        var sent = 0
        while sent < data.count {
            var frame: [UInt8] = []
            if sent == 0 {
                frame = [0xA5, writeFlashCommand | writeFlag,
                         UInt8(data.count & 0xFF), UInt8((data.count >> 8) & 0xFF), 0, 0,
                         UInt8(crc & 0xFF), UInt8(crc >> 8)]
            }
            let chunk = data[sent..<min(data.count, sent + frameSize - frame.count)]
            frame += chunk
            sent += chunk.count
            frames.append(frame + [UInt8](repeating: 0, count: frameSize - frame.count))
        }
        return frames
    }

    /// Writes a whole configuration block to the stick's flash. The stick restarts if it accepts.
    ///
    /// The stick checks the transfer, not the contents, so the checks are made here before a single
    /// frame is sent:
    /// - the block passes its own checksum;
    /// - it is for the same device type and firmware as `current`, what the caller last read;
    /// - a fresh read with this token still returns exactly `current`. That proves the token and
    ///   cipher are right at this moment, and keeps the write from being the first request after
    ///   READ_CPUID, which the stick answers with a stale frame.
    public mutating func writeBlock(_ block: VKBBlock, token: [UInt8], replacing current: VKBBlock) throws -> VKBWriteStatus {
        guard block.isIntact, current.isIntact else { throw VKBError.blockNotIntact }
        guard block.typeID == current.typeID, block.firmware == current.firmware else {
            throw VKBError.blockForOtherDevice
        }
        guard try readBlock(token: token) == current else { throw VKBError.stickChanged }

        let cipher = VKBBytes.rc4(block.bytes, key: Array(token.prefix(15)))
        for frame in Self.writeFrames(data: cipher) {
            try transport.send(frame)
        }
        transport.pause(milliseconds: 60)
        let reply = try transport.receive()
        guard reply.count >= 4 else { throw VKBError.malformedFrame }
        return VKBWriteStatus(word: UInt32(reply[0]) | UInt32(reply[1]) << 8 | UInt32(reply[2]) << 16 | UInt32(reply[3]) << 24)
    }
}
