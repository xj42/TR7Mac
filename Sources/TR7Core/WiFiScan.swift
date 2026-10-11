import Foundation

public struct WiFiAccessPoint: Identifiable, Sendable, Equatable {
    public let bssid: String
    public let ssid: String
    public let channel: Int
    public let type: String
    public let rssi: Int
    public let security: String
    public var id: String { bssid }
}

public struct WiFiScanReport: Sendable, Equatable {
    public let raw: Data
    public let accessPoints: [WiFiAccessPoint]

    public init(_ raw: Data) throws {
        guard let text = String(data: raw, encoding: .utf8) else {
            throw TR7Error.invalid("The Wi-Fi scan report is not UTF-8 text.")
        }
        let lines = text.components(separatedBy: .newlines)
        guard let footer = lines.last(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("No.Of AP Found:") }),
              let expected = Int(footer.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") else {
            throw TR7Error.invalid("The Wi-Fi scan report has no final access-point count.")
        }
        var parsed: [WiFiAccessPoint] = []
        for line in lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 6 else { continue }
            let bssid = fields[0]
            guard Self.validBSSID(bssid),
                  let channel = Int(fields[fields.count - 4]), (1...196).contains(channel),
                  let rssi = Int(fields[fields.count - 2]), (-127...0).contains(rssi),
                  !fields[fields.count - 3].isEmpty, !fields[fields.count - 1].isEmpty else { continue }
            parsed.append(WiFiAccessPoint(
                bssid: bssid,
                ssid: fields[1..<(fields.count - 4)].joined(separator: ","),
                channel: channel,
                type: fields[fields.count - 3],
                rssi: rssi,
                security: fields[fields.count - 1]
            ))
        }
        guard expected >= 0, parsed.count == expected else {
            throw TR7Error.invalid("The Wi-Fi scan reported \(expected) access points but contained \(parsed.count) valid entries.")
        }
        self.raw = raw
        accessPoints = parsed
    }

    private static func validBSSID(_ value: String) -> Bool {
        let octets = value.split(separator: ":", omittingEmptySubsequences: false)
        return octets.count == 6 && octets.allSatisfy { octet in
            octet.count == 2 && octet.allSatisfy { $0.isHexDigit }
        }
    }
}

extension SensorClient {
    /// Runs the firmware's access-point scan and validates its complete GS2200
    /// text report. The terminator is the same one consumed by TR7 for Windows.
    public func scanAccessPoints(timeoutSeconds: Int = 30) async throws -> WiFiScanReport {
        guard (1...180).contains(timeoutSeconds) else { throw TR7Error.invalid("Use a Wi-Fi scan timeout of 1–180 seconds.") }
        try Task.checkCancellation()
        let transport = try factory(); defer { transport.close() }
        _ = try transport.exchange(Packet(command: 0x78, payload: Data(repeating: 0, count: 4)))
        defer { _ = try? transport.exchange(Packet(command: 0x7A, payload: Data(repeating: 0, count: 4))) }
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutSeconds)
        let terminator = Data("No.Of AP Found:".utf8)
        var result = Data()
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            let block = try transport.exchange(Packet(command: 0x7B, payload: Data(repeating: 0, count: 4)))
            guard block.count <= 1024 else { throw TR7Error.invalid("The Wi-Fi scan returned an oversized block.") }
            result.append(block)
            if result.range(of: terminator) != nil { return try WiFiScanReport(result) }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw TR7Error.verification("the Wi-Fi scan did not return its final access-point count before timeout")
    }
}
