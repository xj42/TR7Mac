import Foundation

extension Data {
    func text(_ offset: Int, _ count: Int) -> String {
        guard offset >= 0, count >= 0, offset + count <= self.count else { return "" }
        return String(data: dropFirst(offset).prefix(count).prefix { $0 != 0 && $0 != 255 }, encoding: .utf8) ?? ""
    }
    mutating func putText(_ string: String, at offset: Int, length: Int, terminated: Bool = true) throws {
        let bytes = Data(string.utf8)
        guard bytes.count <= length - (terminated ? 1 : 0), !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TR7Error.invalid("This field accepts up to \(length - (terminated ? 1 : 0)) UTF-8 bytes without control characters.")
        }
        replaceSubrange(offset..<offset + length, with: Data(repeating: 0, count: length))
        replaceSubrange(offset..<offset + bytes.count, with: bytes)
    }
    public var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

public struct LoggerNames: Codable, Equatable, Sendable {
    public var device = "", group = "", channel1 = "", channel2 = ""
    public init() {}
    public init(_ data: Data) throws {
        guard data.count >= 74 else { throw TR7Error.invalid("The logger returned an incomplete names block.") }
        device = data.text(0, 26); group = data.text(26, 16); channel1 = data.text(42, 16); channel2 = data.text(58, 16)
    }
    public func encoded() throws -> Data {
        var data = Data(repeating: 0, count: 74)
        try data.putText(device, at: 0, length: 26, terminated: false)
        try data.putText(group, at: 26, length: 16, terminated: false)
        try data.putText(channel1, at: 42, length: 16, terminated: false)
        try data.putText(channel2, at: 58, length: 16, terminated: false)
        return data
    }
}

public struct FullSettings: Sendable {
    public let basic: LoggerSettings
    public let pages: [Int: Data]
    public let responses: [String: Data]
    public let unavailable: [String: String]
    public var names: LoggerNames? { responses["names"].flatMap { try? LoggerNames($0) } }
    public var recording: RecordingSettings? { responses["recording"].flatMap { try? RecordingSettings($0) } }
}

public struct RecordingSettings: Equatable, Sendable {
    public let raw: Data
    public var interval: Int { Int(raw.word(0)) }
    public var endless: Bool { raw[38] & 1 != 0 }
    public var isRecording: Bool { raw[2] == 2 }
    public var configurationIdentity: Data { Data(raw.prefix(4)) + Data(raw[30..<32]) + Data([raw[38]]) }
    public init(_ data: Data) throws {
        guard data.count == 128 else { throw TR7Error.invalid("Unsupported recording settings length.") }
        raw = data
    }
    public func startPacket(interval: Int, endless: Bool, start: Date? = nil, now: Date = Date()) throws -> Packet {
        guard [1, 2, 5, 10, 15, 20, 30, 60, 120, 300, 600, 900, 1200, 1800, 3600].contains(interval) else {
            throw TR7Error.invalid("Select a supported recording interval.")
        }
        // TdTR7wfCom_SetRecTblRecStart_7A: 3D/00, 64-byte recording table.
        // The write table is distinct from the 128-byte read table. Do not copy live readings into it.
        var data = Data(repeating: 0, count: 64)
        data.setWord(UInt16(interval), at: 0)
        data[3] = 0xFF
        guard now.timeIntervalSince1970 >= 0, now.timeIntervalSince1970 < Double(UInt32.max) else { throw TR7Error.invalid("Unsupported recording date.") }
        data.setDword(UInt32(now.timeIntervalSince1970), at: 18)
        data[32] = raw[30]; data[33] = raw[31]
        data[40] = endless ? 1 : 0; data[41] = 0 // Normal mode for TR72A
        if let start {
            let timestamp = start.timeIntervalSince1970
            guard timestamp > now.timeIntervalSince1970, timestamp < Double(UInt32.max) else { throw TR7Error.invalid("Programmed start must be in the future.") }
            data.setDword(UInt32(timestamp), at: 22)
        }
        return Packet(command: 0x3D, payload: data)
    }
}

public enum DeviceAction: String, CaseIterable, Sendable {
    case stopRecording, clearAlarm, clearMaxMin, factoryReset
    public var packet: Packet {
        switch self {
        case .stopRecording: return Packet(command: 0x32, payload: Data(repeating: 0, count: 4))
        case .clearAlarm: return Packet(command: 0x36, parameter: 2)
        case .clearMaxMin: return Packet(command: 0x2D, parameter: 2)
        case .factoryReset: return Packet(command: 0xC4)
        }
    }
}

public struct DownloadedData: Codable, Sendable {
    public let downloadedAt: Date
    public let metadata: Data
    public let samples: Data
    public var count: Int { samples.count / 4 }
    public init(metadata: Data, samples: Data, downloadedAt: Date = Date()) {
        self.metadata = metadata; self.samples = samples; self.downloadedAt = downloadedAt
    }
    public var rawCSV: String {
        var rows = ["sample,channel1_raw,channel2_raw"]
        for index in 0..<count { rows.append("\(index + 1),\(samples.word(index * 4)),\(samples.word(index * 4 + 2))") }
        return rows.joined(separator: "\n") + "\n"
    }
}

extension SensorClient {
    public func readFull() throws -> FullSettings {
        let transport = try factory(); defer { transport.close() }
        let basic = try read(transport)
        var pages = [0: basic.page0, 1: basic.page1], responses: [String: Data] = [:], unavailable: [String: String] = [:]
        func optional(_ key: String, _ packet: Packet) throws {
            do { responses[key] = try transport.exchange(packet) }
            catch TR7Error.rejected(let code) { unavailable[key] = String(format: "Not supported by this logger (0x%02X)", code) }
        }
        for page in 2...4 {
            do {
                let bytes = try transport.exchange(Packet(command: 0x6D, parameter: UInt8(page)))
                guard bytes.count == 256 else { throw TR7Error.invalid("Unsupported network page length.") }
                pages[page] = bytes
            } catch TR7Error.rejected(let code) { unavailable["network\(page - 1)"] = String(format: "Not supported (0x%02X)", code) }
        }
        for (key, packet) in [
            ("names", Packet(command: 0x56)),
            ("current", Packet(command: 0x33, payload: Data(repeating: 0, count: 4))),
            ("recording", Packet(command: 0x55, payload: Data(repeating: 0, count: 4))),
            ("warnings", Packet(command: 0x36)), ("calibration", Packet(command: 0x53)),
            ("resetTimers", Packet(command: 0x2E)),
            ("battery", Packet(command: 0x39, payload: Data(repeating: 0, count: 4))),
            ("firmware", Packet(command: 0x35, payload: Data(repeating: 0, count: 4))),
            ("status", Packet(command: 0x9F))
        ] { try optional(key, packet) }
        return FullSettings(basic: basic, pages: pages, responses: responses, unavailable: unavailable)
    }
    public func readCurrent() throws -> Data {
        let transport = try factory(); defer { transport.close() }
        return try transport.exchange(Packet(command: 0x33, payload: Data(repeating: 0, count: 4)))
    }
    public func readLogs() throws -> Data {
        let transport = try factory(); defer { transport.close() }
        var data = Data()
        for index in 0...1 {
            let block = try transport.exchange(Packet(command: 0x6B, parameter: UInt8(index)))
            guard block.count == 1020 else { throw TR7Error.invalid("Unsupported operation-log length.") }
            data.append(block)
        }
        return data
    }
    public func setNames(_ names: LoggerNames, expected: LoggerNames) throws {
        let bytes = try names.encoded()
        let transport = try factory(); defer { transport.close() }
        let current = try LoggerNames(transport.exchange(Packet(command: 0x56)))
        guard current == expected else { throw TR7Error.changed }
        _ = try transport.exchange(Packet(command: 0x56, parameter: 1, payload: bytes))
        guard try LoggerNames(transport.exchange(Packet(command: 0x56))) == names else { throw TR7Error.verification("the names did not match") }
    }
    public func setTemperatureUnit(fahrenheit: Bool) throws {
        let transport = try factory(); defer { transport.close() }
        _ = try transport.exchange(Packet(command: 0x37, parameter: fahrenheit ? 1 : 0, payload: Data(repeating: 0, count: 4)))
    }
    public func perform(_ action: DeviceAction) throws {
        let transport = try factory(); defer { transport.close() }
        _ = try transport.exchange(action.packet)
    }
    public func startRecording(_ settings: RecordingSettings, interval: Int, endless: Bool, start: Date?) throws {
        let packet = try settings.startPacket(interval: interval, endless: endless, start: start)
        let transport = try factory(); defer { transport.close() }
        let current = try RecordingSettings(transport.exchange(Packet(command: 0x55, payload: Data(repeating: 0, count: 4))))
        guard current.configurationIdentity == settings.configurationIdentity else { throw TR7Error.changed }
        _ = try transport.exchange(packet)
        let actual = try RecordingSettings(transport.exchange(Packet(command: 0x55, payload: Data(repeating: 0, count: 4))))
        guard actual.interval == interval else { throw TR7Error.verification("the recording interval did not match") }
    }
    public func setBlock(page: Int, offset: Int, bytes: Data, expected: Data) throws {
        guard (0...4).contains(page), offset >= 0, !bytes.isEmpty, offset + bytes.count <= 256, expected.count == 256 else {
            throw TR7Error.invalid("Invalid configuration block.")
        }
        try configuration { transport in
            let current = try transport.exchange(Packet(command: 0x6D, parameter: UInt8(page)))
            guard current.count == 256, current.subdata(in: offset..<offset + bytes.count) == expected.subdata(in: offset..<offset + bytes.count) else { throw TR7Error.changed }
            try write(bytes, at: UInt16(page * 256 + offset), transport: transport)
            let actual = try transport.exchange(Packet(command: 0x6D, parameter: UInt8(page)))
            guard actual.count == 256, actual.subdata(in: offset..<offset + bytes.count) == bytes else { throw TR7Error.verification("the configuration block did not match") }
        }
    }
    public func download(count: Int = 0, periodSeconds: Int? = nil, progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> DownloadedData {
        guard (0...30000).contains(count) else { throw TR7Error.invalid("Download range must be between 1 and 30000 readings, or zero for all.") }
        if let periodSeconds {
            guard periodSeconds > 0, count == 0 else { throw TR7Error.invalid("Choose a positive recording period or a reading count, not both.") }
        }
        try Task.checkCancellation()
        let transport = try factory(); defer { transport.close() }
        var requestedCount = count
        var requestedInterval: Int?
        if let periodSeconds {
            let recording = try RecordingSettings(transport.exchange(Packet(command: 0x55)))
            guard [1, 2, 5, 10, 15, 20, 30, 60, 120, 300, 600, 900, 1200, 1800, 3600].contains(recording.interval) else {
                throw TR7Error.invalid("The logger returned an unsupported recording interval.")
            }
            requestedInterval = recording.interval
            // The period ends at the latest stored reading, including when recording has stopped.
            // Division before rounding avoids overflow for large requested periods.
            requestedCount = min(30000, periodSeconds / recording.interval + (periodSeconds % recording.interval == 0 ? 0 : 1))
        }
        try Task.checkCancellation()
        var request = Data(repeating: 0, count: 4); request.setWord(UInt16(requestedCount), at: 0)
        let metadata = try transport.exchange(Packet(command: 0x40, payload: request))
        guard metadata.count == 128 else { throw TR7Error.invalid("Unsupported recording metadata.") }
        if let requestedInterval, Int(metadata.word(0)) != requestedInterval {
            throw TR7Error.invalid("The recording interval changed. Download again to select the requested period.")
        }
        let records = Int(metadata.dword(112))
        guard records <= 30000, requestedCount == 0 || records <= requestedCount else { throw TR7Error.invalid("The logger returned an invalid reading count.") }
        var samples = Data()
        while samples.count < records * 4 {
            if Task.isCancelled { throw CancellationError() }
            let block = try transport.exchange(Packet(command: 0x41))
            guard !block.isEmpty, block.count <= 1024, block.count % 4 == 0, samples.count + block.count <= records * 4 else {
                throw TR7Error.invalid("The download returned an invalid data block.")
            }
            samples.append(block); progress(samples.count / 4, records)
        }
        try Task.checkCancellation()
        if records == 0 { progress(0, 0) }
        return DownloadedData(metadata: metadata, samples: samples)
    }
}
