import Foundation
import TR7Core

private final class TestUploadLogger: LoggerTransport {
    var commands: [Packet] = []
    var events = [Data([0, 0, 1, 0, 0, 0, 2, 0xC0]), Data([1, 0, 2, 0, 0, 0, 0, 1])]
    var closed = false
    var failure = false
    var busyStart = false
    var busyPolls = 0
    func exchange(_ packet: Packet) throws -> Data {
        commands.append(packet)
        if failure { throw TR7Error.timeout }
        if packet.command == 0x79 {
            if busyStart { throw TR7Error.rejected(0x13) }
            return Data()
        }
        if packet.command == 0x7C {
            if busyPolls > 0 { busyPolls -= 1; throw TR7Error.rejected(0x13) }
            return events.removeFirst()
        }
        return Data()
    }
    func close() { closed = true }
}

extension Checks {
    static func uploadChecks() async throws {
        try check(UploadDestinationPreset.webStorage.address == "api.webstorage-service.com/tr7/device/", "TR7A English cloud path")
        try check(UploadDestinationPreset.ondotori.address == "api.webstorage.jp/tr7/device/", "TR7A Japanese cloud path")
        try rejects("Truncated connection result accepted") { _ = try ConnectionTestEvent(Data(repeating: 0, count: 7)) }
        let absent = try ConnectionTestEvent(Data(repeating: 0, count: 8))
        try check(absent.date == nil && !absent.finished && !absent.succeeded, "Empty result cannot imply test success")
        let device = TestUploadLogger(), client = SensorClient(transportFactory: { device })
        let result = try await client.testConnection(profile: 3, pollNanoseconds: 0)
        try check(result.count == 2 && result.last?.succeeded == true && device.closed, "Connection test result stream and cleanup")
        try check(device.commands == [Packet(command: 0x79, payload: Data([3, 0, 0, 0])), Packet(command: 0x7C, payload: Data([0, 0, 0, 0])), Packet(command: 0x7C, payload: Data([1, 0, 0, 0]))], "Independent connection-test USB vectors, start result and cursor")
        let pending = TestUploadLogger(); pending.busyStart = true; pending.busyPolls = 1
        let resumed = try await SensorClient(transportFactory: { pending }).testConnection(profile: 1, pollNanoseconds: 0)
        try check(resumed.last?.succeeded == true && pending.commands.filter { $0.command == 0x7C }.count == 3, "Connection test resumes a retained firmware job and waits while busy")
        let errorDevice = TestUploadLogger(); errorDevice.events = [Data([0, 0, 5, 0, 0, 0, 0, 0x29])]
        let errors = try await SensorClient(transportFactory: { errorDevice }).testConnection(profile: 1, pollNanoseconds: 0)
        try check(errors.count == 1 && errors[0].finished && !errors[0].succeeded && errors[0].description.contains("certificate"), "Test distinguishes server certificate failure")
        let invalidDevice = TestUploadLogger(), invalidClient = SensorClient(transportFactory: { invalidDevice })
        do { _ = try await invalidClient.testConnection(profile: 0); throw CheckFailed(message: "Invalid test network accepted") }
        catch TR7Error.invalid { }
        try check(invalidDevice.commands.isEmpty, "Invalid test rejected before opening")
        invalidDevice.failure = true
        do { _ = try await invalidClient.testConnection(profile: 1); throw CheckFailed(message: "Test transport failure accepted") }
        catch TR7Error.timeout { }
        try check(invalidDevice.closed && invalidDevice.commands.count == 1, "Test start failure closes without retries")
        let fake = FakeLogger(), settingsClient = SensorClient(transportFactory: { fake })
        let original = try await settingsClient.read()
        let disabled = try await settingsClient.setUploadsOff(expected: original)
        try check(!disabled.uploadEnabled && !disabled.scheduledUploadEnabled, "OFF disables both upload mechanisms")
        try check(disabled.page0[194..<256] == original.page0[194..<256], "OFF preserves interval, scheduled times and reserved bytes")
        let writes = fake.commands.filter { $0.command == 0x6C }.count
        do { _ = try await settingsClient.setUploadsOff(expected: original); throw CheckFailed(message: "Stale uploads-off snapshot accepted") }
        catch TR7Error.changed { }
        try check(fake.commands.filter { $0.command == 0x6C }.count == writes && fake.commands.last?.command == 0x50, "Stale OFF prevents write and exits configuration")
        fake.ignoreWrite = true
        // Restore enabled state so ignoring the next OFF write cannot verify successfully.
        fake.page0[192] = 1
        let latest = try await settingsClient.read()
        do { _ = try await settingsClient.setUploadsOff(expected: latest); throw CheckFailed(message: "Unverified uploads-off accepted") }
        catch TR7Error.verification { }
        try check(fake.closed && fake.commands.last?.command == 0x50, "OFF readback failure cleans up")
    }
}
