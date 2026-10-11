import Foundation

public enum TR7Error: Error, LocalizedError {
    case invalid(String), transport(String), timeout, checksum, rejected(UInt8), changed, verification(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .transport(let message): return message
        case .timeout: return "The logger did not respond before the timeout. Check its connection and move the logger closer if using Bluetooth."
        case .checksum: return "The logger response failed its checksum. No response data was accepted."
        case .rejected(let status): return String(format: "The logger rejected the command (status 0x%02X).", status)
        case .changed: return "The settings changed since they were loaded. Reload the logger before saving."
        case .verification(let message): return "The write was sent, but verification failed: \(message). Reload the logger to check its current settings."
        }
    }
}

public struct Packet: Equatable {
    public let command: UInt8
    public let parameter: UInt8
    public let payload: Data
    public init(command: UInt8, parameter: UInt8 = 0, payload: Data = Data()) {
        self.command = command; self.parameter = parameter; self.payload = payload
    }
    public static func crc(_ data: Data) -> UInt16 {
        var value: UInt16 = 0
        for byte in data {
            value ^= UInt16(byte) << 8
            for _ in 0..<8 { value = value & 0x8000 != 0 ? (value &<< 1) ^ 0x1021 : value &<< 1 }
        }
        return value
    }
    public func encoded() throws -> Data {
        guard payload.count <= 4096 else { throw TR7Error.invalid("Command payload is too large.") }
        var bytes = Data([1, command, parameter, UInt8(payload.count & 255), UInt8(payload.count >> 8)])
        bytes.append(payload)
        let checksum = Self.crc(bytes)
        bytes.append(UInt8(checksum >> 8)); bytes.append(UInt8(checksum & 255))
        return bytes
    }
    public static func decode(_ data: Data, expectedCommand: UInt8? = nil) throws -> Packet {
        let bytes = [UInt8](data)
        guard bytes.count >= 7, bytes[0] == 1 else { throw TR7Error.invalid("Invalid logger packet header.") }
        let length = Int(bytes[3]) | Int(bytes[4]) << 8
        guard length <= 4096, bytes.count == length + 7 else { throw TR7Error.invalid("Invalid logger packet length.") }
        let checksum = UInt16(bytes[length + 5]) << 8 | UInt16(bytes[length + 6])
        guard crc(Data(bytes.prefix(length + 5))) == checksum else { throw TR7Error.checksum }
        if let expectedCommand, bytes[1] != expectedCommand { throw TR7Error.invalid("The response belongs to a different command.") }
        return Packet(command: bytes[1], parameter: bytes[2], payload: Data(bytes[5..<(length + 5)]))
    }
}

extension Data {
    func word(_ offset: Int) -> UInt16 { UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8 }
    func dword(_ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }
    mutating func setWord(_ value: UInt16, at offset: Int) {
        self[startIndex + offset] = UInt8(value & 255); self[startIndex + offset + 1] = UInt8(value >> 8)
    }
    mutating func setDword(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { self[startIndex + offset + index] = UInt8((value >> (8 * index)) & 255) }
    }
}
