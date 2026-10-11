import Foundation
import TR7Core

struct CheckFailed: Error { let message: String }
func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CheckFailed(message: message) }
}
func rejects(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw CheckFailed(message: message)
}
final class FakeLogger: LoggerTransport {
    var page0 = Data(repeating: 0xA5, count: 256)
    var page1 = Data(repeating: 0xB6, count: 256)
    var clock = Data([26, 10, 11, 12, 0, 0])
    var warnings = Checks.warningVector
    var commands: [Packet] = []
    var ignoreWrite = false
    var failWrite = false
    var closed = false
    init() {
        page0[192] = 1; page0[193] = 1
        page0.replaceSubrange(196..<200, with: Data([88, 2, 0, 0]))
        page1.replaceSubrange(0..<124, with: Data(repeating: 0, count: 124))
        page1.replaceSubrange(0..<13, with: Data("192.168.0.150".utf8))
        page1[124] = 7; page1[125] = 0; page1[126] = 0xB8; page1[127] = 0x22
    }
    func exchange(_ packet: Packet) throws -> Data {
        commands.append(packet)
        switch packet.command {
        case 0x6D: return packet.parameter == 0 ? page0 : page1
        case 0x6F:
            if packet.parameter == 0 { clock = packet.payload }
            return clock
        case 0x56: return Data("Patio\0".utf8) + Data(repeating: 0, count: 68)
        case 0x36:
            if packet.parameter == 1 {
                if failWrite { throw TR7Error.timeout }
                if !ignoreWrite { warnings = packet.payload }
                return Data()
            }
            return warnings
        case 0x6C:
            if failWrite { throw TR7Error.timeout }
            if !ignoreWrite {
                if packet.payload.prefix(2) == Data([0, 1]) { page1.replaceSubrange(0..<128, with: packet.payload.dropFirst(2)) }
                else { page0.replaceSubrange(192..<256, with: packet.payload.dropFirst(2)) }
            }
            return Data()
        default: return Data()
        }
    }
    func close() { closed = true }
}

@main struct Checks {
    // Independent bytes using the Windows SetLimit_7A field order, not the Swift encoder.
    static let warningVector = Data([0xD7, 0xCA, 30, 0, 0, 0, 0x84, 3, 0x14, 5, 60, 0, 0, 0, 0xB0, 4, 8, 7])
    static func main() async {
        do {
            try bluetoothRegistryChecks()
            try recordedDataChecks()
            try await recordingDownloadChecks()
            try await calibrationChecks()
            try await certificateChecks()
            try await uploadChecks()
            try await wifiScanChecks()
            try check(Packet.crc(Data("123456789".utf8)) == 0x31C3, "CRC-XMODEM golden vector")
            let vector = Data([1, 0x6D, 1, 0, 0, 0xFD, 0x35])
            try check(try Packet(command: 0x6D, parameter: 1).encoded() == vector, "EEPROM command vector")
            try check(try Packet.decode(vector).parameter == 1, "Packet roundtrip")
            var corrupt = vector; corrupt[2] ^= 1
            try rejects("Corrupt CRC accepted") { _ = try Packet.decode(corrupt) }
            try rejects("Wrong command accepted") { _ = try Packet.decode(vector, expectedCommand: 0x6F) }
            try rejects("Truncated packet accepted") { _ = try Packet.decode(vector.dropLast()) }
            try rejects("Invalid calendar date accepted") { _ = try LoggerClock(payload: Data([26, 2, 30, 0, 0, 0])) }
            try check(try BluetoothProtocol.wirePacket(Packet(command: 0x6D, parameter: 1)).payload == Data([0, 0, 0, 0]), "BLE read padding")
            try check(try BluetoothProtocol.unlock(passcode: "001234").payload == Data([0xD2, 4, 0, 0]), "BLE passcode byte order")
            try check(try BluetoothProtocol.unlock(passcode: "").payload == Data(repeating: 0, count: 4), "Unlocked BLE device")
            try rejects("Invalid BLE passcode accepted") { _ = try BluetoothProtocol.unlock(passcode: "12a456") }
            let clockWrite = Packet(command: 0x6F, payload: Data([26, 10, 11, 12, 0, 0]))
            try check(try BluetoothProtocol.wirePacket(clockWrite) == clockWrite, "BLE writes preserve payload")
            let fake = FakeLogger(); let client = SensorClient(transportFactory: { fake })
            let initial = try await client.read()
            try check(initial.port == 8888 && initial.destinationMode == 7 && initial.intervalSeconds == 600, "Settings field offsets")
            try rejects("URL scheme accepted") { _ = try initial.destinationBlock(address: "http://192.168.0.56", port: 8888) }
            try rejects("Invalid port accepted") { _ = try initial.destinationBlock(address: "192.168.0.56", port: 0) }
            try rejects("Oversize address accepted") { _ = try initial.destinationBlock(address: String(repeating: "é", count: 62), port: 80) }
            let changed = try await client.setDestination(address: "192.168.0.56", port: 8888, expected: initial)
            try check(changed.address == "192.168.0.56" && changed.port == 8888, "Destination write/readback")
            try check(changed.destinationMode == 7 && changed.page1[128..<256] == initial.page1[128..<256], "Destination preserves mode and trailing bytes")
            try check(fake.commands.contains { $0.command == 0x6C && $0.parameter == 0x1B && $0.payload.count == 130 }, "Destination write framing")
            let updated = try await client.setInterval(seconds: 1200, enabled: false, expected: changed)
            try check(!updated.uploadEnabled && updated.scheduledUploadEnabled && updated.intervalSeconds == 1200, "Interval write/readback")
            try check(updated.page0[200..<256] == initial.page0[200..<256] && updated.page0[0..<192] == initial.page0[0..<192], "Schedule and other settings preserved")
            let writesBefore = fake.commands.filter { $0.command == 0x6C }.count
            do { _ = try await client.setDestination(address: "new.example", port: 80, expected: initial); throw CheckFailed(message: "Stale settings accepted") }
            catch TR7Error.changed { }
            try check(fake.commands.filter { $0.command == 0x6C }.count == writesBefore, "Stale snapshot causes no write")
            fake.ignoreWrite = true
            do { _ = try await client.setDestination(address: "ignored.example", port: 80, expected: updated); throw CheckFailed(message: "Unverified write accepted") }
            catch TR7Error.verification { }
            try check(fake.commands.last?.command == 0x50 && fake.commands.last?.parameter == 0, "Configuration mode released after verification failure")
            fake.ignoreWrite = false; fake.failWrite = true
            do { _ = try await client.setInterval(seconds: 600, enabled: true, expected: updated); throw CheckFailed(message: "Transport failure accepted") }
            catch TR7Error.timeout { }
            try check(fake.commands.last?.command == 0x50 && fake.closed, "Configuration mode and connection released after write failure")
            let clock = try LoggerClock(payload: Data([26, 10, 11, 20, 30, 0]))
            let clockResult = try await client.setClock(clock)
            try check(clockResult.clock == clock, "Clock write/readback")
            try await warningChecks()
            print("PASS: protocol safety, recorded ranges, upload tests, adjustment, certificates, Bluetooth registration, and warning settings")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8)); exit(1)
        }
    }
    static func warningChecks() async throws {
        let original = try WarningSettings(warningVector)
        try check(original.lower1Enabled && !original.upper1Enabled && !original.sensor1Enabled, "Channel 1 warning flags")
        try check(original.lower2Enabled && !original.upper2Enabled && !original.sensor2Enabled && !original.batteryEnabled, "Channel 2 and battery warning flags")
        try check(original.lower1 == -10 && original.upper1 == 30 && original.lower2 == 20 && original.upper2 == 80, "Warning threshold field order")
        try check(try original.encoded() == warningVector, "Unchanged warnings preserve every byte")
        let switches: [(WritableKeyPath<WarningSettings, Bool>, Int, UInt8)] = [
            (\.upper1Enabled, 1, 0x01), (\.lower1Enabled, 1, 0x02), (\.sensor1Enabled, 1, 0x04),
            (\.lower2Enabled, 1, 0x08), (\.upper2Enabled, 1, 0x10), (\.sensor2Enabled, 1, 0x20), (\.batteryEnabled, 0, 0x08)
        ]
        for (key, offset, mask) in switches {
            var settings = original, expected = warningVector
            settings[keyPath: key].toggle(); expected[offset] ^= mask
            try check(try settings.encoded() == expected, "Each warning switch changes only its documented bit")
        }
        var target = original
        target.upper1Enabled = true; target.lower1Enabled = false; target.sensor1Enabled = true
        target.upper2Enabled = true; target.lower2Enabled = false; target.sensor2Enabled = true; target.batteryEnabled = true
        let enabledVector = Data([0xDF, 0xF5, 30, 0, 0, 0, 0x84, 3, 0x14, 5, 60, 0, 0, 0, 0xB0, 4, 8, 7])
        try check(try target.encoded() == enabledVector, "Mixed warning switches preserve reserved bits and limits")
        target.lower1 = -10.5; target.upper2 = 90.1; target.delay1 = 300; target.delay2 = 3600
        let writtenVector = Data([0xDF, 0xF5, 0x2C, 1, 0, 0, 0x7F, 3, 0x14, 5, 0x10, 0x0E, 0, 0, 0xB0, 4, 0x6D, 7])
        try check(try target.encoded() == writtenVector, "Warning limits and judgment-time golden vector")
        let warningWrite = Packet(command: 0x36, parameter: 1, payload: writtenVector)
        try check(try BluetoothProtocol.wirePacket(warningWrite) == warningWrite, "Bluetooth warning writes preserve the recovered payload")
        let export = try JSONSerialization.jsonObject(with: JSONEncoder().encode(WarningSummary(target))) as? [String: Any]
        try check(export?["batteryEnabled"] as? Bool == true && export?["lower1Enabled"] as? Bool == false && export?["delay2"] as? Int == 3600, "Decoded warning settings export")
        try check(export?["raw"] == nil, "Warning export omits protocol bytes")
        for seconds in WarningSettings.judgmentTimes {
            var settings = original; settings.delay1 = seconds; settings.delay2 = seconds
            _ = try settings.encoded()
        }
        try rejects("Truncated warnings accepted") { _ = try WarningSettings(warningVector.dropLast()) }
        for seconds in [-1, 0, 31, 3601, Int.max] {
            var settings = original; settings.delay1 = seconds
            try rejects("Unsupported judgment time accepted") { _ = try settings.encoded() }
            settings = original; settings.delay2 = seconds
            try rejects("Unsupported channel 2 judgment time accepted") { _ = try settings.encoded() }
        }
        var legacy = warningVector; legacy[2] = 0; legacy[6] = 0xFF; legacy[7] = 0xFF; legacy[1] &= ~0x02
        let existing = try WarningSettings(legacy)
        try check(try existing.encoded() == legacy, "Existing judgment times and disabled sentinel limits survive unchanged")
        var enableSentinel = existing; enableSentinel.lower1Enabled = true
        try rejects("Enabled sentinel limit accepted") { _ = try enableSentinel.encoded() }
        for number in [Double.nan, Double.infinity, -100.1, 150.1] {
            var settings = original; settings.upper1 = number
            try rejects("Invalid threshold accepted") { _ = try settings.encoded() }
        }
        var inverted = original; inverted.lower1 = 40; inverted.upper1Enabled = true
        try rejects("Inverted enabled warning limits accepted") { _ = try inverted.encoded() }
        inverted.upper1Enabled = false
        _ = try inverted.encoded() // A disabled limit does not constrain the other limit.
        let fake = FakeLogger(), client: SensorClient
        client = SensorClient(transportFactory: { fake })
        try await client.setWarnings(target, expected: warningVector)
        try check(fake.warnings == writtenVector && fake.closed, "Warning command readback and connection cleanup")
        try check(fake.commands == [Packet(command: 0x36), Packet(command: 0x36, parameter: 1, payload: writtenVector), Packet(command: 0x36)], "Warning read/write/read sequence")
        let writesBefore = fake.commands.filter { $0.parameter == 1 }.count
        do { try await client.setWarnings(target, expected: warningVector); throw CheckFailed(message: "Stale warning settings accepted") }
        catch TR7Error.changed { }
        try check(fake.commands.filter { $0.parameter == 1 }.count == writesBefore, "Stale warning snapshot causes no write")
        var changed = try WarningSettings(writtenVector); changed.batteryEnabled = false
        fake.ignoreWrite = true
        do { try await client.setWarnings(changed, expected: writtenVector); throw CheckFailed(message: "Unverified warning write accepted") }
        catch TR7Error.verification { }
        try check(fake.closed, "Warning connection closes after verification failure")
        fake.ignoreWrite = false; fake.failWrite = true
        do { try await client.setWarnings(changed, expected: writtenVector); throw CheckFailed(message: "Warning transport failure accepted") }
        catch TR7Error.timeout { }
        try check(fake.closed, "Warning connection closes after transport failure")
        let commandsBefore = fake.commands.count
        changed.delay1 = 31
        do { try await client.setWarnings(changed, expected: writtenVector); throw CheckFailed(message: "Invalid warning write accepted") }
        catch TR7Error.invalid { }
        try check(fake.commands.count == commandsBefore, "Invalid warnings never open the transport")
        do { try await client.setWarnings(original, expected: writtenVector); throw CheckFailed(message: "Mismatched source warning block accepted") }
        catch TR7Error.invalid { }
        try check(fake.commands.count == commandsBefore, "Mismatched warning source causes no communication")
    }
}
