import Foundation
import TR7Core

private final class TestWiFiScanLogger: LoggerTransport {
    var commands: [Packet] = []
    var blocks: [Data]
    var closed = false
    init(_ blocks: [Data]) { self.blocks = blocks }
    func exchange(_ packet: Packet) throws -> Data {
        commands.append(packet)
        if packet.command == 0x7B { return blocks.isEmpty ? Data() : blocks.removeFirst() }
        return Data()
    }
    func close() { closed = true }
}

extension Checks {
    static func wifiScanChecks() async throws {
        let first = Data("OK\r\n       BSSID              SSID                     Channel  Type  RSSI Security\r\nAA:BB:CC:DD:EE:01,Office, Guest,6,INFRA,-42,WPA2-PERSONAL\r\n".utf8)
        let second = Data("AA:BB:CC:DD:EE:02,                         ,11,INFRA,-71,OPEN\r\nNo.Of AP Found:2\r\n".utf8)
        let logger = TestWiFiScanLogger([first, second])
        let report = try await SensorClient(transportFactory: { logger }).scanAccessPoints(timeoutSeconds: 1)
        try check(report.accessPoints.count == 2 && report.accessPoints[0].ssid == "Office,Guest", "Wi-Fi scan parses comma-containing SSIDs")
        try check(report.accessPoints[1].ssid.isEmpty && report.accessPoints[1].channel == 11 && report.accessPoints[1].rssi == -71, "Wi-Fi scan parses hidden networks and radio details")
        try check(logger.commands == [Packet(command: 0x78, payload: Data(repeating: 0, count: 4)), Packet(command: 0x7B, payload: Data(repeating: 0, count: 4)), Packet(command: 0x7B, payload: Data(repeating: 0, count: 4)), Packet(command: 0x7A, payload: Data(repeating: 0, count: 4))], "Wi-Fi scan start, chunk and stop vectors")
        try check(logger.closed, "Wi-Fi scan closes its connection")
        try rejects("Wi-Fi scan count mismatch accepted") { _ = try WiFiScanReport(Data("AA:BB:CC:DD:EE:01,Test,1,INFRA,-40,OPEN\r\nNo.Of AP Found:2\r\n".utf8)) }
        try rejects("Wi-Fi scan malformed BSSID accepted") { _ = try WiFiScanReport(Data("invalid,Test,1,INFRA,-40,OPEN\r\nNo.Of AP Found:1\r\n".utf8)) }
    }
}
