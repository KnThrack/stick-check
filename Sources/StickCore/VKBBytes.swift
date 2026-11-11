/// Checksums and the cipher used by VKB's configuration protocol.
public enum VKBBytes {
    /// CRC-16/MODBUS: initial value 0xFFFF, reflected polynomial 0xA001, no final XOR.
    public static func crc16Modbus(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    /// The STM32 hardware CRC: polynomial 0x04C11DB7, initial value 0xFFFFFFFF, fed 32-bit
    /// little-endian words most-significant bit first, no final XOR. Trailing bytes that do not
    /// fill a word are ignored.
    public static func crc32STM32(_ data: ArraySlice<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        var index = data.startIndex
        while index + 4 <= data.endIndex {
            let word = UInt32(data[index]) | UInt32(data[index + 1]) << 8
                | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
            crc ^= word
            for _ in 0..<32 {
                crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
            index += 4
        }
        return crc
    }

    /// RC4. Encrypting and decrypting are the same operation.
    public static func rc4(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        guard !key.isEmpty else { return data }
        var state = (0...255).map { UInt8($0) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(state[i]) + Int(key[i % key.count])) & 0xFF
            state.swapAt(i, j)
        }
        var i = 0
        j = 0
        return data.map { byte in
            i = (i + 1) & 0xFF
            j = (j + Int(state[i])) & 0xFF
            state.swapAt(i, j)
            return byte ^ state[(Int(state[i]) + Int(state[j])) & 0xFF]
        }
    }
}
