import Foundation

public struct RecordedSample: Identifiable, Sendable {
    public let id: Int, date: Date?, channel1: Double?, channel2: Double?
    public let raw1: UInt16, raw2: UInt16
}
extension DownloadedData {
    public func validated() throws -> DownloadedData {
        guard metadata.count == 128, samples.count % 4 == 0, count <= 30000,
              Int(metadata.dword(112)) == count, metadata.word(0) > 0 else { throw TR7Error.invalid("This is not a valid TR7Mac recording archive.") }
        return self
    }
    public var intervalSeconds: Int { metadata.count == 128 ? Int(metadata.word(0)) : 0 }
    public var lastSampleDate: Date? {
        guard metadata.count == 128, metadata.dword(74) > 0, metadata.dword(74) != UInt32.max else { return nil }
        return Date(timeIntervalSince1970: Double(metadata.dword(74)))
    }
    public var readings: [RecordedSample] {
        guard metadata.count == 128, samples.count % 4 == 0 else { return [] }
        return (0..<count).map { index in
            let raw1 = samples.word(index * 4), raw2 = samples.word(index * 4 + 2)
            return RecordedSample(id: index + 1, date: lastSampleDate?.addingTimeInterval(-Double(count - index - 1) * Double(intervalSeconds)),
                                  channel1: CurrentReadings.value(raw1, attribute: metadata[30]), channel2: CurrentReadings.value(raw2, attribute: metadata[31]), raw1: raw1, raw2: raw2)
        }
    }
    /// Keeps original sample identifiers and values; recordings without a known clock have no date matches.
    public func readings(in dates: ClosedRange<Date>) -> [RecordedSample] {
        readings.filter { $0.date.map(dates.contains) ?? false }
    }
    public var csv: String { csv(for: readings) }
    public func csv(for readings: [RecordedSample]) -> String {
        let formatter = ISO8601DateFormatter()
        var rows = ["sample,time_utc,channel1_\(CurrentReadings.unit(metadata.count > 31 ? metadata[30] : 0)),channel2_\(CurrentReadings.unit(metadata.count > 31 ? metadata[31] : 0)),channel1_raw,channel2_raw"]
        for sample in readings {
            rows.append([String(sample.id), sample.date.map(formatter.string) ?? "", sample.channel1.map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "",
                         sample.channel2.map { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0) } ?? "", String(sample.raw1), String(sample.raw2)].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

public struct OperationLogEntry: Identifiable, Sendable {
    public let id: Int, date: Date, category: UInt8, code: UInt8
    public var description: String {
        if category == 0 && code == 1 { return "Operation succeeded" }
        if category == 2 && code == 1 { return "Upload started" }
        let errors: [UInt8: String] = [0x1E: "Access point unavailable", 0x1F: "DHCP failed", 0x20: "DNS failed", 0x21: "Server connection failed", 0x22: "Time server connection failed", 0x23: "Data upload failed", 0x24: "Server data request failed", 0x25: "Warning upload failed", 0x26: "HTTP response error", 0x27: "HTTP buffer error", 0x28: "TLS error", 0x29: "Server certificate verification failed", 0x32: "Low battery prevented Wi-Fi", 0x33: "Low battery prevented HTTP", 0x34: "SNTP synchronization failed", 0x4D: "Factory reset"]
        return errors[code] ?? String(format: "Event %02X / %02X", category, code)
    }
    public static func decode(_ bytes: Data) throws -> [OperationLogEntry] {
        guard bytes.count == 2040 else { throw TR7Error.invalid("Unsupported operation log.") }
        return stride(from: 0, to: bytes.count, by: 6).compactMap { at in
            let timestamp = bytes.dword(at)
            guard timestamp != 0, timestamp != UInt32.max else { return nil }
            return OperationLogEntry(id: at / 6, date: Date(timeIntervalSince1970: Double(timestamp)), category: bytes[at + 4], code: bytes[at + 5])
        }.sorted { $0.date > $1.date }
    }
    public static func csv(_ entries: [OperationLogEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        return "time_utc,category,code,event\n" + entries.map { "\(formatter.string(from: $0.date)),\(String(format: "%02X", $0.category)),\(String(format: "%02X", $0.code)),\($0.description)" }.joined(separator: "\n") + "\n"
    }
}
