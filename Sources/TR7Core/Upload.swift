import Foundation

public enum UploadDestinationPreset: String, CaseIterable, Sendable {
    case webStorage = "T&D WebStorage Service"
    case ondotori = "Ondotori Web Storage"
    public var address: String {
        switch self {
        case .webStorage: return "api.webstorage-service.com/tr7/device/"
        case .ondotori: return "api.webstorage.jp/tr7/device/"
        }
    }
}

/// A record returned by the vendor's 7C connection-test result command.
public struct ConnectionTestEvent: Identifiable, Sendable {
    public let index: UInt16
    public let date: Date?
    public let category: UInt8, code: UInt8
    public var id: UInt16 { index }
    public init(_ bytes: Data) throws {
        guard bytes.count == 8 else { throw TR7Error.invalid("Incomplete connection-test result.") }
        index = bytes.word(0)
        let timestamp = bytes.dword(2)
        date = timestamp == 0 || timestamp == UInt32.max ? nil : Date(timeIntervalSince1970: Double(timestamp))
        category = bytes[6]; code = bytes[7]
    }
    public var succeeded: Bool { date != nil && category == 0 && code == 1 }
    public var finished: Bool { date != nil && category == 0 && code != 0 }
    public var description: String {
        if code == 0xC0 { return "Test upload started" }
        return OperationLogEntry(id: Int(index), date: date ?? .distantPast, category: category, code: code).description
    }
}

extension SensorClient {
    /// Explicitly disables both upload mechanisms without discarding stored scheduled times.
    public func setUploadsOff(expected: LoggerSettings) throws -> LoggerSettings {
        try configuration { transport in
            let current = try read(transport)
            guard current.page0[192..<256] == expected.page0[192..<256] else { throw TR7Error.changed }
            var block = Data(current.page0[192..<256]); block[0] = 0; block[1] = 0
            try write(block, at: 192, transport: transport)
            let result = try read(transport)
            guard result.page0[192..<256] == block else { throw TR7Error.verification("uploads were not disabled") }
            return result
        }
    }

    /// Uses saved device settings, keeps one transport open, and never retries the start command.
    public func testConnection(profile: Int, timeoutSeconds: Int = 90,
                               pollNanoseconds: UInt64 = 1_000_000_000,
                               progress: @Sendable (ConnectionTestEvent) -> Void = { _ in }) async throws -> [ConnectionTestEvent] {
        guard (1...3).contains(profile), (1...180).contains(timeoutSeconds), pollNanoseconds <= 5_000_000_000 else {
            throw TR7Error.invalid("Select Wi-Fi profile 1–3 and a test timeout of 1–180 seconds.")
        }
        try Task.checkCancellation()
        let transport = try factory(); defer { transport.close() }
        // Firmware 1.20 queues job 0x10 and returns the normal SCMD success
        // status with an empty payload. Completion is reported only by 7C.
        do {
            _ = try transport.exchange(Packet(command: 0x79, payload: Data([UInt8(profile), 0, 0, 0])))
        } catch TR7Error.rejected(0x13) {
            // Firmware retains job 0x10 until its result stream is consumed. A
            // previous client can therefore leave a valid test pending.
        }
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutSeconds)
        var cursor: UInt16 = 0, events: [ConnectionTestEvent] = []
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let bytes: Data
            do {
                bytes = try transport.exchange(Packet(command: 0x7C, payload: Data([UInt8(cursor & 255), 0, 0, 0])))
            } catch TR7Error.rejected(0x13) {
                try await Task.sleep(nanoseconds: pollNanoseconds)
                continue
            }
            let event = try ConnectionTestEvent(bytes)
            if event.date != nil {
                guard event.index >= cursor, event.index < 255 else { throw TR7Error.invalid("Unexpected connection-test result index.") }
                cursor = event.index + 1
                events.append(event); progress(event)
                if event.finished { return events }
            }
            try await Task.sleep(nanoseconds: pollNanoseconds)
        }
        throw TR7Error.verification("the connection test did not return a final result before its timeout; check the operation log")
    }
}
