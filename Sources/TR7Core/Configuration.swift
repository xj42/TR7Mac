import Foundation

public struct CurrentReadings: Codable, Sendable {
    public let channel1: Double?, channel2: Double?
    public let maximum1: Double?, minimum1: Double?, maximum2: Double?, minimum2: Double?
    public let attribute1: UInt8, attribute2: UInt8
    public init(_ bytes: Data) throws {
        guard bytes.count >= 14 else { throw TR7Error.invalid("Incomplete current readings.") }
        attribute1 = bytes[12]; attribute2 = bytes[13]
        channel1 = Self.value(bytes.word(0), attribute: attribute1)
        channel2 = Self.value(bytes.word(2), attribute: attribute2)
        maximum1 = Self.value(bytes.word(4), attribute: attribute1); minimum1 = Self.value(bytes.word(6), attribute: attribute1)
        maximum2 = Self.value(bytes.word(8), attribute: attribute2); minimum2 = Self.value(bytes.word(10), attribute: attribute2)
    }
    public static func value(_ raw: UInt16, attribute: UInt8) -> Double? {
        guard raw < 0xF000, [UInt8(0x0D), 0xD0].contains(attribute) else { return nil }
        return (Double(raw) - 1000) / 10
    }
    public static func unit(_ attribute: UInt8) -> String { attribute == 0x0D ? "°C" : attribute == 0xD0 ? "%RH" : "Unknown" }
}

/// Passwords are deliberately excluded from Codable settings exports.
public struct NetworkProfile: Equatable, Sendable {
    public var enabled = false, dhcp = true
    public var ssid = "", password = "", address = "0.0.0.0", mask = "0.0.0.0", gateway = "0.0.0.0"
    public var dns1 = "0.0.0.0", dns2 = "0.0.0.0", proxy = "", proxyPort = 0
    public let raw: Data
    public var securityCode: UInt16 { raw.word(34) }
    public init(_ page: Data) throws {
        guard page.count == 256 else { throw TR7Error.invalid("Incomplete network profile.") }
        raw = page; enabled = page[0] != 0; ssid = page.text(2, 32); dhcp = page[36] == 0
        password = page.text(64, 64); proxy = page.text(128, 126); proxyPort = Int(page.word(254))
        address = Self.ip(page, 38); mask = Self.ip(page, 42); gateway = Self.ip(page, 46)
        dns1 = Self.ip(page, 50); dns2 = Self.ip(page, 54)
    }
    private static func ip(_ bytes: Data, _ at: Int) -> String { bytes[at..<at + 4].map(String.init).joined(separator: ".") }
    static func ipBytes(_ text: String) throws -> Data {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              parts.allSatisfy({ UInt8($0) != nil }) else { throw TR7Error.invalid("Enter four IPv4 numbers between 0 and 255.") }
        return Data(parts.map { UInt8($0)! })
    }
    public func networkBlock() throws -> Data {
        var block = Data(raw.prefix(128))
        if enabled {
            guard !ssid.isEmpty, ssid.utf8.count <= 32, ssid.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 }) else {
                throw TR7Error.invalid("Wi-Fi names must contain 1–32 printable ASCII bytes.")
            }
            if password != raw.text(64, 64) {
                let isHex = password.count == 64 && password.allSatisfy(\.isHexDigit)
                guard isHex || ((8...63).contains(password.utf8.count) && password.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value <= 126 })) else {
                    throw TR7Error.invalid("Wi-Fi passwords require 8–63 printable ASCII characters, or 64 hexadecimal digits.")
                }
            }
        }
        block[0] = enabled ? 1 : 0; block[36] = dhcp ? 0 : 1
        try block.putText(ssid, at: 2, length: 32, terminated: false)
        try block.putText(password, at: 64, length: 64, terminated: false)
        for (at, text) in [(38, address), (42, mask), (46, gateway), (50, dns1), (54, dns2)] {
            block.replaceSubrange(at..<at + 4, with: try Self.ipBytes(text))
        }
        return block
    }
    public func proxyBlock() throws -> Data {
        guard (0...65535).contains(proxyPort), proxy.isEmpty || proxyPort > 0,
              !proxy.contains("://"), !proxy.contains(":"), !proxy.contains("/") else { throw TR7Error.invalid("Enter a proxy host and port (1–65535), or clear the host to disable it.") }
        var block = Data(raw.suffix(128))
        try block.putText(proxy, at: 0, length: 126)
        block.setWord(UInt16(proxy.isEmpty ? 0 : proxyPort), at: 126)
        return block
    }
    public var summary: NetworkSummary {
        NetworkSummary(enabled: enabled, ssid: ssid, dhcp: dhcp, address: address, mask: mask, gateway: gateway,
                       dns1: dns1, dns2: dns2, proxy: proxy, proxyPort: proxyPort, securityCode: securityCode, passwordConfigured: !password.isEmpty)
    }
}
public struct NetworkSummary: Codable, Sendable {
    public let enabled: Bool, ssid: String, dhcp: Bool, address: String, mask: String, gateway: String
    public let dns1: String, dns2: String, proxy: String, proxyPort: Int, securityCode: UInt16, passwordConfigured: Bool
}

public struct TimeConfiguration: Equatable, Sendable {
    public var offsetMinutes: Int, daylightSaving: Bool, daylightMinutes: Int
    public var sntpEnabled: Bool, server: String
    public init(_ settings: LoggerSettings) {
        offsetMinutes = settings.timeZoneMinutes; daylightSaving = settings.daylightSaving; daylightMinutes = settings.daylightMinutes
        sntpEnabled = settings.page1.word(128) != 0; server = settings.page1.text(130, 62)
    }
    public func zoneBlock(from page: Data) throws -> Data {
        guard (-720...840).contains(offsetMinutes), (0...120).contains(daylightMinutes), page.count == 256 else { throw TR7Error.invalid("Use a timezone from UTC−12 to UTC+14 and daylight offset from 0 to 120 minutes.") }
        var bytes = Data(page[128..<134]); bytes.setWord(UInt16(bitPattern: Int16(offsetMinutes)), at: 0)
        bytes[2] = daylightSaving ? 1 : 0; bytes.setWord(UInt16(daylightMinutes), at: 4)
        return bytes
    }
    public func serverBlock(from page: Data) throws -> Data {
        guard page.count == 256, !sntpEnabled || (!server.isEmpty && !server.contains(where: \.isWhitespace) && !server.contains("://")) else { throw TR7Error.invalid("Enter an SNTP server host without a URL scheme.") }
        var bytes = Data(page[128..<192]); bytes.setWord(sntpEnabled ? 1 : 0, at: 0)
        try bytes.putText(server, at: 2, length: 62)
        return bytes
    }
}

public struct MaxMinTimer: Equatable, Sendable {
    public var enabled: Bool, hour: Int, minute: Int, second: Int
    public init(_ bytes: Data) throws {
        guard bytes.count == 6 else { throw TR7Error.invalid("Incomplete max/min reset timer.") }
        func bcd(_ byte: UInt8) -> Int { Int(byte >> 4) * 10 + Int(byte & 15) }
        enabled = bytes[0] != 0; second = bcd(bytes[2]); minute = bcd(bytes[3]); hour = bcd(bytes[4])
        _ = try encoded()
    }
    public func encoded() throws -> Data {
        guard (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { throw TR7Error.invalid("Select a valid daily reset time.") }
        func bcd(_ number: Int) -> UInt8 { UInt8(number / 10 * 16 + number % 10) }
        return Data([enabled ? 1 : 0, 2, bcd(second), bcd(minute), bcd(hour), 0])
    }
}

public struct WarningSettings: Equatable, Sendable {
    public static let judgmentTimes = [30, 60, 120, 300, 600, 900, 1200, 1800, 3600]
    public let raw: Data
    public var lower1: Double, upper1: Double, lower2: Double, upper2: Double
    public var delay1: Int, delay2: Int
    public var lower1Enabled: Bool, upper1Enabled: Bool, sensor1Enabled: Bool
    public var lower2Enabled: Bool, upper2Enabled: Bool, sensor2Enabled: Bool
    public var batteryEnabled: Bool
    public init(_ bytes: Data) throws {
        guard bytes.count == 18 else { throw TR7Error.invalid("Incomplete warning settings.") }
        raw = bytes
        func value(_ at: Int) -> Double { (Double(bytes.word(at)) - 1000) / 10 }
        lower1 = value(6); upper1 = value(8); lower2 = value(14); upper2 = value(16)
        delay1 = Int(bytes.dword(2)); delay2 = Int(bytes.dword(10))
        upper1Enabled = bytes[1] & 0x01 != 0; lower1Enabled = bytes[1] & 0x02 != 0; sensor1Enabled = bytes[1] & 0x04 != 0
        lower2Enabled = bytes[1] & 0x08 != 0; upper2Enabled = bytes[1] & 0x10 != 0; sensor2Enabled = bytes[1] & 0x20 != 0
        batteryEnabled = bytes[0] & 0x08 != 0
    }
    public func encoded() throws -> Data {
        // Keep existing nonstandard judgment times readable, but use the Windows choices for changes.
        guard (Self.judgmentTimes.contains(delay1) || delay1 == Int(raw.dword(2))),
              (Self.judgmentTimes.contains(delay2) || delay2 == Int(raw.dword(10))) else {
            throw TR7Error.invalid("Choose a warning judgment time from 30 seconds to 60 minutes.")
        }
        let limits = [(6, lower1, lower1Enabled), (8, upper1, upper1Enabled), (14, lower2, lower2Enabled), (16, upper2, upper2Enabled)]
        guard (!lower1Enabled || !upper1Enabled || lower1 <= upper1),
              (!lower2Enabled || !upper2Enabled || lower2 <= upper2),
              limits.allSatisfy({ at, value, enabled in
                  value.isFinite && ((!enabled && value == (Double(raw.word(at)) - 1000) / 10) || (-100...150).contains(value))
              }) else {
            throw TR7Error.invalid("Enter valid warning limits; an enabled lower limit must not exceed its enabled upper limit.")
        }
        var bytes = raw
        // Windows uses byte 1 for channel limits/sensor warnings and byte 0 bit 3 for battery warnings.
        bytes[0] = (bytes[0] & ~0x08) | (batteryEnabled ? 0x08 : 0)
        bytes[1] &= ~0x3F
        for (enabled, mask): (Bool, UInt8) in [(upper1Enabled, 0x01), (lower1Enabled, 0x02), (sensor1Enabled, 0x04),
                                             (lower2Enabled, 0x08), (upper2Enabled, 0x10), (sensor2Enabled, 0x20)] {
            if enabled { bytes[1] |= mask }
        }
        // Preserve an untouched limit exactly, including device sentinel values in disabled fields.
        for (at, value) in [(6, lower1), (8, upper1), (14, lower2), (16, upper2)] {
            if value != (Double(raw.word(at)) - 1000) / 10 { bytes.setWord(UInt16((value * 10 + 1000).rounded()), at: at) }
        }
        if delay1 != Int(raw.dword(2)) { bytes.setDword(UInt32(delay1), at: 2) }
        if delay2 != Int(raw.dword(10)) { bytes.setDword(UInt32(delay2), at: 10) }
        return bytes
    }
}

public struct SettingsSummary: Codable, Sendable {
    public let name: String, address: String, port: UInt16, destinationMode: UInt16
    public let uploadEnabled: Bool, scheduledUploadEnabled: Bool, intervalSeconds: UInt32
    public let timeZoneMinutes: Int, daylightSaving: Bool, daylightMinutes: Int, clock: LoggerClock, readAt: Date
    public let names: LoggerNames?, networks: [NetworkSummary], readings: CurrentReadings?, firmware: String?
    public let warnings: WarningSummary?
    public init(_ full: FullSettings) {
        let basic = full.basic
        name = basic.name; address = basic.address; port = basic.port; destinationMode = basic.destinationMode
        uploadEnabled = basic.uploadEnabled; scheduledUploadEnabled = basic.scheduledUploadEnabled; intervalSeconds = basic.intervalSeconds
        timeZoneMinutes = basic.timeZoneMinutes; daylightSaving = basic.daylightSaving; daylightMinutes = basic.daylightMinutes
        clock = basic.clock; readAt = basic.readAt; names = full.names
        networks = (2...4).compactMap { full.pages[$0].flatMap { try? NetworkProfile($0).summary } }
        readings = full.responses["current"].flatMap { try? CurrentReadings($0) }
        firmware = full.responses["firmware"].map { $0.text(8, max(0, $0.count - 8)) }
        warnings = full.responses["warnings"].flatMap { try? WarningSettings($0) }.map(WarningSummary.init)
    }
}

public struct WarningSummary: Codable, Sendable {
    public let lower1: Double, upper1: Double, lower2: Double, upper2: Double
    public let delay1: Int, delay2: Int
    public let lower1Enabled: Bool, upper1Enabled: Bool, sensor1Enabled: Bool
    public let lower2Enabled: Bool, upper2Enabled: Bool, sensor2Enabled: Bool, batteryEnabled: Bool
    public init(_ settings: WarningSettings) {
        lower1 = settings.lower1; upper1 = settings.upper1; lower2 = settings.lower2; upper2 = settings.upper2
        delay1 = settings.delay1; delay2 = settings.delay2
        lower1Enabled = settings.lower1Enabled; upper1Enabled = settings.upper1Enabled; sensor1Enabled = settings.sensor1Enabled
        lower2Enabled = settings.lower2Enabled; upper2Enabled = settings.upper2Enabled; sensor2Enabled = settings.sensor2Enabled
        batteryEnabled = settings.batteryEnabled
    }
}

extension SensorClient {
    public func initializeCalibration(expected: Data) throws {
        try initializeCalibrationWithHistory(expected: expected)
    }
    public func setNetwork(_ profile: NetworkProfile, number: Int, expected: Data) throws {
        guard (1...3).contains(number) else { throw TR7Error.invalid("Choose a Wi-Fi profile from 1 to 3.") }
        // Validate both blocks before any device write, then use one configuration session.
        let network = try profile.networkBlock(), proxy = try profile.proxyBlock()
        try configuration { transport in
            let current = try transport.exchange(Packet(command: 0x6D, parameter: UInt8(number + 1)))
            guard current == expected else { throw TR7Error.changed }
            try write(network, at: UInt16((number + 1) * 256), transport: transport)
            try write(proxy, at: UInt16((number + 1) * 256 + 128), transport: transport)
            let actual = try transport.exchange(Packet(command: 0x6D, parameter: UInt8(number + 1)))
            guard actual == network + proxy else { throw TR7Error.verification("the Wi-Fi profile did not match") }
        }
    }
    public func setTimeConfiguration(_ time: TimeConfiguration, expected: LoggerSettings) throws {
        let zone = try time.zoneBlock(from: expected.page0), server = try time.serverBlock(from: expected.page1)
        try configuration { transport in
            let current = try read(transport)
            guard current.page0[128..<134] == expected.page0[128..<134], current.page1[128..<192] == expected.page1[128..<192] else { throw TR7Error.changed }
            try write(zone, at: 128, transport: transport); try write(server, at: 384, transport: transport)
            let actual = try read(transport)
            guard actual.page0[128..<134] == zone, actual.page1[128..<192] == server else { throw TR7Error.verification("the time settings did not match") }
        }
    }
    public func setWarnings(_ warnings: WarningSettings, expected: Data) throws {
        guard expected.count == 18, warnings.raw == expected else { throw TR7Error.invalid("Reload the warning settings before saving.") }
        try verifiedCommand(read: Packet(command: 0x36), write: Packet(command: 0x36, parameter: 1, payload: warnings.encoded()), expected: expected)
    }
    public func setResetTimer(_ timer: MaxMinTimer, channel: Int, expected: Data) throws {
        guard (1...2).contains(channel), expected.count == 12 else { throw TR7Error.invalid("Select a max/min timer channel.") }
        let bytes = try timer.encoded(); var result = expected
        result.replaceSubrange((channel - 1) * 6..<channel * 6, with: bytes)
        try verifiedCommand(read: Packet(command: 0x2E), write: Packet(command: 0x2E, parameter: UInt8(channel), payload: bytes), expected: expected, result: result)
    }
    func verifiedCommand(read: Packet, write: Packet, expected: Data, result: Data? = nil) throws {
        let transport = try factory(); defer { transport.close() }
        guard try transport.exchange(read) == expected else { throw TR7Error.changed }
        _ = try transport.exchange(write)
        guard try transport.exchange(read) == (result ?? write.payload) else { throw TR7Error.verification("the settings did not match") }
    }
    public func setPasscode(_ code: String) throws {
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }), let value = UInt32(code) else { throw TR7Error.invalid("Enter a six-digit numeric Bluetooth passcode.") }
        var bytes = Data(repeating: 0, count: 4); bytes.setDword(value, at: 0)
        let transport = try factory(); defer { transport.close() }
        _ = try transport.exchange(Packet(command: 0x75, payload: bytes))
    }
    public func setBluetoothEnabled(_ enabled: Bool) throws {
        let transport = try factory(); defer { transport.close() }
        _ = try transport.exchange(Packet(command: 0x3A, parameter: enabled ? 1 : 0))
    }
    public func readCertificateInfo() throws -> [Data] {
        let transport = try factory(); defer { transport.close() }
        return try [transport.exchange(Packet(command: 0xCB, payload: Data([7, 0]))), transport.exchange(Packet(command: 0xCE, payload: Data([7, 0])))]
    }
}
