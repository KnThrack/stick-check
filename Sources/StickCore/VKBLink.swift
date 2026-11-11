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

    public var description: String {
        switch self {
        case .noAnswer: "The stick did not answer the request."
        case .damagedTransfer: "The transfer arrived damaged (CRC-16 mismatch)."
        case .malformedFrame: "The stick returned a frame of the wrong size."
        case .wrongBlockSize(let size): "Expected a 4096-byte configuration block, got \(size) bytes."
        }
    }
}

/// The only requests this code can build. All three read; none changes anything on the stick.
///
/// VKB's protocol also has long writes (flag 0x80) and short commands (second byte 0x5A) that
/// restart, recalibrate, reset or reflash the stick. They are deliberately not representable here.
public enum VKBReadCommand: UInt8, Sendable, CaseIterable {
    /// The configuration block stored in flash.
    case readFlash = 0x02
    /// The copy of the configuration block in RAM.
    case readRAM = 0x03
    /// The session token (the microcontroller's unique ID, lightly wrapped).
    case readCPUID = 0x0B
}

/// Read side of VKB's configuration protocol, as documented by the vkbdevcfg-explained project
/// (docs/PROTOCOL.md) and verified there on a Gladiator EVO R at firmware 2.20.C.
public struct VKBLink {
    public static let reportID: UInt8 = 0x59
    public static let frameSize = 128
    public static let blockSize = 0x1000
    static let headerSize = 8
    static let readFlag: UInt8 = 0xC0
    /// Fixed key from the vendor tool that unwraps the session token in the READ_CPUID reply.
    static let cpuidKey: [UInt8] = [0xF9, 0x14, 0x62, 0xA0, 0xD2, 0x6C, 0x8D, 0x4E, 0x88, 0xC6, 0xB0, 0x4C, 0x29]

    private let transport: any FeatureTransport
    /// How many times a request had to be repeated because the stick answered with a stale frame.
    public private(set) var retries = 0

    public init(transport: any FeatureTransport) {
        self.transport = transport
    }

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
}
