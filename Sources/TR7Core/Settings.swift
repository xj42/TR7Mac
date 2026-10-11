import Foundation

public struct LoggerClock: Equatable, Codable, Sendable {
    public let year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int
    public init(payload: Data) throws {
        let bytes = [UInt8](payload)
        guard bytes.count == 6 else { throw TR7Error.invalid("Unexpected logger clock length.") }
        year = 2000 + Int(bytes[0]); month = Int(bytes[1]); day = Int(bytes[2])
        hour = Int(bytes[3]); minute = Int(bytes[4]); second = Int(bytes[5])
        _ = try encoded()
    }
    public init(date: Date, timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        year = parts.year!; month = parts.month!; day = parts.day!
        hour = parts.hour!; minute = parts.minute!; second = parts.second!
    }
    public func encoded() throws -> Data {
        guard (2000...2099).contains(year), (1...12).contains(month), (1...31).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else {
            throw TR7Error.invalid("The logger clock must be a valid date between 2000 and 2099.")
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date) == components else {
            throw TR7Error.invalid("The logger returned an invalid calendar date.")
        }
        return Data([UInt8(year - 2000), UInt8(month), UInt8(day), UInt8(hour), UInt8(minute), UInt8(second)])
    }
    public var description: String {
        String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
    }
    public var comparisonDate: Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}

public struct LoggerSettings: Codable, Equatable, Sendable {
    public let name: String
    public let address: String
    public let port: UInt16
    /// TR7A modes recovered from Windows secure/plain HTTP setters: 0 HTTPS, 7 HTTP.
    public let destinationMode: UInt16
    public let uploadEnabled: Bool
    public let scheduledUploadEnabled: Bool
    public let intervalSeconds: UInt32
    public let timeZoneMinutes: Int
    public let daylightSaving: Bool
    public let daylightMinutes: Int
    public let clock: LoggerClock
    public let readAt: Date
    public let page0: Data
    public let page1: Data
    public init(page0: Data, page1: Data, clock: LoggerClock, name: String = "T&D logger", readAt: Date = Date()) throws {
        guard page0.count == 256, page1.count == 256 else { throw TR7Error.invalid("The logger uses an unsupported settings layout.") }
        guard page0[192] <= 1, page0[193] <= 1, page0.dword(196) <= 86400 else {
            throw TR7Error.invalid("The logger upload settings do not match the TR7A layout.")
        }
        let addressBytes = page1.prefix(124).prefix { $0 != 0 }
        guard let address = String(data: addressBytes, encoding: .utf8) else { throw TR7Error.invalid("The upload address is not valid UTF-8.") }
        self.page0 = page0; self.page1 = page1; self.clock = clock; self.name = name; self.readAt = readAt
        self.address = address; port = page1.word(126); destinationMode = page1.word(124)
        uploadEnabled = page0[192] != 0; scheduledUploadEnabled = page0[193] != 0; intervalSeconds = page0.dword(196)
        timeZoneMinutes = Int(Int16(bitPattern: page0.word(128)))
        daylightSaving = page0[130] != 0; daylightMinutes = Int(Int16(bitPattern: page0.word(132)))
    }
    public func destinationBlock(address: String, port: Int, mode: UInt16? = nil) throws -> Data {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Data(trimmed.utf8)
        guard !bytes.isEmpty, bytes.count <= 123, !trimmed.contains("://"),
              !trimmed.contains(":"), !trimmed.contains("#"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw TR7Error.invalid("Enter a host or IPv4 address, optionally followed by a path, up to 123 UTF-8 bytes. Enter the port separately.")
        }
        guard (1...65535).contains(port) else { throw TR7Error.invalid("The server port must be between 1 and 65535.") }
        // The vendor setter writes 128 bytes at EEPROM offset 0x0100.
        var block = Data(page1.prefix(128))
        block.replaceSubrange(0..<124, with: Data(repeating: 0, count: 124))
        block.replaceSubrange(0..<bytes.count, with: bytes)
        block.setWord(UInt16(port), at: 126)
        if let mode {
            guard mode == 0 || mode == 7 else { throw TR7Error.invalid("Select HTTP or HTTPS.") }
            block.setWord(mode, at: 124)
        }
        return block
    }
    public func intervalBlock(seconds: Int, enabled: Bool) throws -> Data {
        guard (1...86400).contains(seconds) else { throw TR7Error.invalid("Upload interval must be between 1 second and 24 hours.") }
        // Preserve scheduled upload times and undocumented/reserved bytes.
        var block = Data(page0[192..<256])
        block[0] = enabled ? 1 : 0
        block.setDword(UInt32(seconds), at: 4)
        return block
    }
}
