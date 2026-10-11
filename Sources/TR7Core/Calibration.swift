import Foundation

public struct CalibrationCoefficients: Codable, Equatable, Sendable {
    public let slope: UInt16
    public let offset: Int16
    public var isIdentity: Bool { slope == 1000 && offset == 0 }
    public var equation: String { String(format: "y = %.3fx %+.3f", Double(slope) / 1000, Double(offset) / 1000) }
    public init(slope: UInt16 = 1000, offset: Int16 = 0) { self.slope = slope; self.offset = offset }
    func validated() throws -> Self {
        guard (1...2000).contains(slope), abs(Int(offset)) <= 30000 else {
            throw TR7Error.invalid("Adjustment requires a slope above 0 and at most 2, and an offset within ±30.")
        }
        return self
    }
}

public struct CalibrationSettings: Equatable, Sendable {
    public let raw: Data
    public let channels: [CalibrationCoefficients]
    public var adjustedAt: Date? { raw.dword(0) == 0 ? nil : Date(timeIntervalSince1970: Double(raw.dword(0))) }
    public init(_ bytes: Data) throws {
        guard bytes.count == 12 else { throw TR7Error.invalid("Incomplete sensor adjustment settings.") }
        raw = bytes
        channels = [CalibrationCoefficients(slope: bytes.word(4), offset: Int16(bitPattern: bytes.word(6))),
                    CalibrationCoefficients(slope: bytes.word(8), offset: Int16(bitPattern: bytes.word(10)))]
    }
    init(channels: [CalibrationCoefficients], date: Date) throws {
        guard channels.count == 2, date.timeIntervalSince1970 >= 0, date.timeIntervalSince1970 < Double(UInt32.max) else {
            throw TR7Error.invalid("Unsupported sensor adjustment date or channels.")
        }
        var bytes = Data(repeating: 0, count: 12)
        bytes.setDword(UInt32(date.timeIntervalSince1970), at: 0)
        for index in channels.indices {
            let channel = try channels[index].validated()
            bytes.setWord(channel.slope, at: 4 + index * 4)
            bytes.setWord(UInt16(bitPattern: channel.offset), at: 6 + index * 4)
        }
        try self.init(bytes)
    }
}

public enum CalibrationMethod: Int, Codable, CaseIterable, Sendable {
    case onePoint, twoPoint
    public var title: String { self == .onePoint ? "1 point" : "2 points" }
}

public struct CalibrationChannelDraft: Codable, Equatable, Sendable {
    public var enabled = false
    public var method = CalibrationMethod.onePoint
    public var before1 = 0.0, after1 = 0.0, before2 = 10.0, after2 = 10.0
    public init() {}
    public func coefficients() throws -> CalibrationCoefficients {
        let points = method == .onePoint ? [(before1, after1)] : [(before1, after1), (before2, after2)]
        guard points.allSatisfy({ before, after in
            before.isFinite && after.isFinite && abs(before) <= 3276.7 && abs(after) <= 3276.7 &&
            abs(before * 10 - (before * 10).rounded()) < 0.000001 &&
            abs(after * 10 - (after * 10).rounded()) < 0.000001 && abs(after - before) <= 5.000001
        }) else { throw TR7Error.invalid("Enter adjustment points in units of 0.1, with each correction within ±5.") }
        let slope: Double, offset: Double
        if method == .onePoint { slope = 1; offset = roundedCoefficient(after1 - before1) }
        else {
            guard before1 != before2 else { throw TR7Error.invalid("Two-point adjustment requires distinct before values.") }
            // Windows rounds a to three places before calculating b from the second point.
            slope = roundedCoefficient((after2 - after1) / (before2 - before1))
            offset = roundedCoefficient(after2 - slope * before2)
        }
        guard slope.isFinite, offset.isFinite, slope > 0, slope <= 2, abs(offset) <= 30 else {
            throw TR7Error.invalid("Adjustment requires a slope above 0 and at most 2, and an offset within ±30.")
        }
        return try CalibrationCoefficients(slope: UInt16((slope * 1000).rounded()), offset: Int16((offset * 1000).rounded())).validated()
    }
}

private func roundedCoefficient(_ value: Double) -> Double { (value * 1000).rounded(.toNearestOrAwayFromZero) / 1000 }

public struct CalibrationDraft: Codable, Equatable, Sendable {
    public var channels = [CalibrationChannelDraft(), CalibrationChannelDraft()]
    public init() {}
    public func applying(to current: CalibrationSettings, date: Date = Date()) throws -> CalibrationSettings {
        guard channels.count == 2, channels.contains(where: \.enabled) else { throw TR7Error.invalid("Select at least one channel to adjust.") }
        let coefficients = try channels.enumerated().map { index, draft -> CalibrationCoefficients in
            let old = current.channels[index]
            guard draft.enabled else { return old }
            let correction = try draft.coefficients()
            // The vendor composes adjustments; initialization is a separate operation.
            let slope = (Double(old.slope) * Double(correction.slope) / 1000).rounded()
            let offset = (Double(old.offset) * Double(correction.slope) / 1000 + Double(correction.offset)).rounded()
            guard slope > 0, slope <= 2000, abs(offset) <= 30000 else { throw TR7Error.invalid("The combined adjustment exceeds the allowed slope or offset. Initialize the sensor adjustment first.") }
            return try CalibrationCoefficients(slope: UInt16(slope), offset: Int16(offset)).validated()
        }
        return try CalibrationSettings(channels: coefficients, date: date)
    }

    // Tr7WF.exe 0x40A081–0x40A245: header, then two 40-byte C structures.
    private static let header = Data("TR7WF-Adjustment\n".utf8)
    public init(windowsFile data: Data) throws {
        guard data.count == Self.header.count + 80 || data.count == Self.header.count + 160,
              data.prefix(Self.header.count) == Self.header else { throw TR7Error.invalid("This is not a TR7 for Windows adjustment file.") }
        self.init()
        for index in 0..<2 {
            let block = Data(data.dropFirst(Self.header.count + index * 40).prefix(40))
            guard block.dword(0) <= 1, let method = CalibrationMethod(rawValue: Int(block.dword(4))) else { throw TR7Error.invalid("Unsupported adjustment file channel flags.") }
            channels[index].enabled = block.dword(0) != 0; channels[index].method = method
            var numbers: [Double] = []
            for offset in stride(from: 8, to: 40, by: 8) {
                let field = block.subdata(in: offset..<offset + 8)
                guard let text = String(data: field.prefix { $0 != 0 }, encoding: .ascii) else { throw TR7Error.invalid("Invalid adjustment file number.") }
                guard text.isEmpty || Double(text)?.isFinite == true else { throw TR7Error.invalid("Invalid adjustment file number.") }
                numbers.append(text.isEmpty ? 0 : Double(text)!)
            }
            channels[index].before1 = numbers[0]; channels[index].before2 = numbers[1]
            channels[index].after1 = numbers[2]; channels[index].after2 = numbers[3]
            if channels[index].enabled { _ = try channels[index].coefficients() }
        }
    }
    public func windowsFile() throws -> Data {
        guard channels.count == 2 else { throw TR7Error.invalid("Adjustment files require two channels.") }
        var result = Self.header
        for draft in channels {
            if draft.enabled { _ = try draft.coefficients() }
            var block = Data(repeating: 0, count: 40)
            block.setDword(draft.enabled ? 1 : 0, at: 0); block.setDword(UInt32(draft.method.rawValue), at: 4)
            for (index, number) in [draft.before1, draft.before2, draft.after1, draft.after2].enumerated() {
                guard number.isFinite else { throw TR7Error.invalid("Invalid adjustment file number.") }
                let text = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), number)
                try block.putText(text, at: 8 + index * 8, length: 8)
            }
            result.append(block)
        }
        return result
    }
    public func historyBlock(from bytes: Data, settings: CalibrationSettings, original: CalibrationSettings? = nil, initialized: Bool = false) throws -> Data {
        guard channels.count == 2 else { throw TR7Error.invalid("Adjustment history requires two channels.") }
        if !initialized { for channel in channels where channel.enabled { _ = try channel.coefficients() } }
        _ = try CalibrationHistoryEntry.decode(bytes)
        let timestamp = settings.raw.dword(0)
        var entries = (0..<4).map { Data(bytes.dropFirst($0 * 15).prefix(15)) }.filter { $0.dword(2) != 0 }
        if initialized {
            var entry = Data(repeating: 0, count: 15); entry[1] = 3; entry.setDword(timestamp, at: 2); entries.append(entry)
        } else {
            for (index, draft) in channels.enumerated() where draft.enabled {
                var entry = Data(repeating: 0, count: 15)
                entry[0] = UInt8(index + 1); entry[1] = UInt8(draft.method.rawValue + 1); entry.setDword(timestamp, at: 2)
                for (offset, number) in [(6, draft.before1), (10, draft.after1)] + (draft.method == .twoPoint ? [(8, draft.before2), (12, draft.after2)] : []) {
                    entry.setWord(UInt16(bitPattern: Int16((number * 10).rounded())), at: offset)
                }
                entries.append(entry)
            }
        }
        var result = bytes
        result.replaceSubrange(0..<60, with: Data(repeating: 0, count: 60))
        for (index, entry) in entries.suffix(4).enumerated() { result.replaceSubrange(index * 15..<index * 15 + 15, with: entry) }
        // Windows stores the two scaled slopes as IEEE-754 doubles after the four history entries.
        for index in 0..<2 {
            var scaledSlope = Double(settings.channels[index].slope)
            if !initialized, let original, channels[index].enabled {
                scaledSlope = Double(original.channels[index].slope) * Double(try channels[index].coefficients().slope) / 1000
            }
            let bits = scaledSlope.bitPattern
            for byte in 0..<8 { result[60 + index * 8 + byte] = UInt8(truncatingIfNeeded: bits >> (byte * 8)) }
        }
        return result
    }
}

public struct CalibrationHistoryEntry: Equatable, Sendable, Identifiable {
    public let index: Int, channel: Int, method: Int
    public let unitCode: UInt8
    public let date: Date
    public let before1: Double, after1: Double, before2: Double, after2: Double
    public var id: Int { index }
    public var description: String {
        if method == 3 { return "Initialized both channels (y = x)" }
        let first = String(format: "CH%d: %.1f → %.1f", channel, before1, after1)
        return method == 2 ? first + String(format: "; %.1f → %.1f (2 points)", before2, after2) : first + " (1 point)"
    }
    public static func decode(_ bytes: Data) throws -> [Self] {
        guard bytes.count == 80 else { throw TR7Error.invalid("Incomplete sensor adjustment history.") }
        return try (0..<4).compactMap { index in
            let at = index * 15
            guard bytes.dword(at + 2) != 0 else { return nil }
            let channel = Int(bytes[at]), method = Int(bytes[at + 1])
            guard (method == 3 && channel == 0) || ((1...2).contains(channel) && (1...2).contains(method)) else {
                throw TR7Error.invalid("Unsupported sensor adjustment history entry.")
            }
            func value(_ offset: Int) -> Double { Double(Int16(bitPattern: bytes.word(at + offset))) / 10 }
            return Self(index: index, channel: channel, method: method, unitCode: bytes[at + 14], date: Date(timeIntervalSince1970: Double(bytes.dword(at + 2))),
                        before1: value(6), after1: value(10), before2: value(8), after2: value(12))
        }
    }
}

extension SensorClient {
    public func readCalibrationHistory() throws -> [CalibrationHistoryEntry] {
        let transport = try factory(); defer { transport.close() }
        return try CalibrationHistoryEntry.decode(transport.exchange(Packet(command: 0x60)))
    }
    public func setCalibration(_ draft: CalibrationDraft, expected: Data, date: Date = Date()) throws -> CalibrationSettings {
        let old = try CalibrationSettings(expected)
        let proposed = try draft.applying(to: old, date: date)
        return try applyCalibration(proposed, draft: draft, expected: expected, initialized: false)
    }
    public func initializeCalibrationWithHistory(expected: Data, date: Date = Date()) throws {
        _ = try CalibrationSettings(expected)
        let proposed = try CalibrationSettings(channels: [CalibrationCoefficients(), CalibrationCoefficients()], date: date)
        _ = try applyCalibration(proposed, draft: CalibrationDraft(), expected: expected, initialized: true)
    }
    private func applyCalibration(_ proposed: CalibrationSettings, draft: CalibrationDraft, expected: Data, initialized: Bool) throws -> CalibrationSettings {
        let transport = try factory(); defer { transport.close() }
        let recording = try RecordingSettings(transport.exchange(Packet(command: 0x55, payload: Data(repeating: 0, count: 4))))
        guard !recording.isRecording else { throw TR7Error.invalid("Stop recording before changing sensor adjustment.") }
        guard try transport.exchange(Packet(command: 0x53)) == expected else { throw TR7Error.changed }
        let history = try transport.exchange(Packet(command: 0x60))
        let updatedHistory = try draft.historyBlock(from: history, settings: proposed, original: CalibrationSettings(expected), initialized: initialized)
        _ = try transport.exchange(Packet(command: 0x52, payload: proposed.raw))
        let actual = try CalibrationSettings(transport.exchange(Packet(command: 0x53)))
        guard actual.raw.suffix(8) == proposed.raw.suffix(8) else { throw TR7Error.verification("the sensor adjustment did not match") }
        do {
            _ = try transport.exchange(Packet(command: 0x61, payload: updatedHistory))
            guard try transport.exchange(Packet(command: 0x60)) == updatedHistory else { throw TR7Error.verification("the adjustment history did not match") }
        } catch {
            throw TR7Error.verification("the sensor coefficients were saved, but adjustment history was not verified: \(error.localizedDescription)")
        }
        return actual
    }
}
