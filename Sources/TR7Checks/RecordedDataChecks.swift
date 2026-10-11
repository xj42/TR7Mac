import Foundation
import TR7Core

private final class RecordingLogger: LoggerTransport {
    var commands: [Packet] = []
    var closed = false
    var interval = 60
    var returnedInterval = 60
    var records = 2
    var failBlock = false
    var badMetadata = false
    var blocks: [Data] = [Data([0x4C, 0x04, 0xDC, 0x05]), Data([0xB0, 0x04, 0xD0, 0x07])]
    func exchange(_ packet: Packet) throws -> Data {
        commands.append(packet)
        switch packet.command {
        case 0x55:
            var data = Data(repeating: 0, count: 128)
            data[0] = UInt8(interval & 255); data[1] = UInt8(interval >> 8)
            return data
        case 0x40:
            if badMetadata { return Data(repeating: 0, count: 127) }
            var data = Data(repeating: 0, count: 128)
            data[0] = UInt8(returnedInterval & 255); data[1] = UInt8(returnedInterval >> 8)
            data[112] = UInt8(records & 255); data[113] = UInt8(records >> 8)
            return data
        case 0x41:
            if failBlock { throw TR7Error.timeout }
            return blocks.isEmpty ? Data() : blocks.removeFirst()
        default: throw CheckFailed(message: "Recording download issued an unexpected command")
        }
    }
    func close() { closed = true }
}

private final class DownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Int, Int)] = []
    func append(_ done: Int, _ total: Int) { lock.lock(); defer { lock.unlock() }; storage.append((done, total)) }
    var values: [(Int, Int)] { lock.lock(); defer { lock.unlock() }; return storage }
}

extension Checks {
    static func recordingDownloadChecks() async throws {
        let fake = RecordingLogger(), progress = DownloadProgress()
        let client = SensorClient(transportFactory: { fake })
        let result = try await client.download(periodSeconds: 61) { progress.append($0, $1) }
        try check(fake.commands.map(\.command) == [0x55, 0x40, 0x41, 0x41] && fake.commands[1].payload == Data([2, 0, 0, 0]), "Recent period reads interval and rounds up without writes")
        try check(result.count == 2 && fake.closed && progress.values.map { $0.0 } == [1, 2] && progress.values.allSatisfy { $0.1 == 2 }, "Period download data, progress and cleanup")
        let before = fake.commands.count
        for period in [0, -1] {
            do { _ = try await client.download(periodSeconds: period); throw CheckFailed(message: "Invalid period accepted") }
            catch TR7Error.invalid { }
        }
        do { _ = try await client.download(count: 100, periodSeconds: 3600); throw CheckFailed(message: "Conflicting download ranges accepted") }
        catch TR7Error.invalid { }
        try check(fake.commands.count == before, "Invalid ranges cause no transport communication")

        let large = RecordingLogger(); large.records = 0
        _ = try await SensorClient(transportFactory: { large }).download(periodSeconds: Int.max)
        try check(large.commands[1].payload == Data([0x30, 0x75, 0, 0]) && large.closed, "Huge periods saturate at device capacity without integer overflow")
        let empty = RecordingLogger(), emptyProgress = DownloadProgress(); empty.records = 0
        _ = try await SensorClient(transportFactory: { empty }).download { emptyProgress.append($0, $1) }
        try check(empty.commands.count == 1 && empty.commands[0].payload == Data([0, 0, 0, 0]) && emptyProgress.values.count == 1 && emptyProgress.values[0].0 == 0 && emptyProgress.values[0].1 == 0, "All-data empty download skips interval lookup and finishes progress")

        let unsupported = RecordingLogger(); unsupported.interval = 0
        do { _ = try await SensorClient(transportFactory: { unsupported }).download(periodSeconds: 3600); throw CheckFailed(message: "Zero recording interval accepted") }
        catch TR7Error.invalid { }
        try check(unsupported.commands.map(\.command) == [0x55] && unsupported.closed, "Invalid recording interval stops before requesting data")
        let changed = RecordingLogger(); changed.returnedInterval = 120
        do { _ = try await SensorClient(transportFactory: { changed }).download(periodSeconds: 3600); throw CheckFailed(message: "Changed recording interval accepted") }
        catch TR7Error.invalid { }
        try check(changed.commands.map(\.command) == [0x55, 0x40] && changed.closed, "Changed interval stops before data blocks")
        let excess = RecordingLogger(); excess.records = 3
        do { _ = try await SensorClient(transportFactory: { excess }).download(count: 2); throw CheckFailed(message: "Excess recording count accepted") }
        catch TR7Error.invalid { }
        try check(excess.commands.map(\.command) == [0x40] && excess.closed, "Count mismatch closes before transferring samples")
        let malformed = RecordingLogger(); malformed.badMetadata = true
        do { _ = try await SensorClient(transportFactory: { malformed }).download(); throw CheckFailed(message: "Truncated download metadata accepted") }
        catch TR7Error.invalid { }
        try check(malformed.closed, "Malformed download metadata closes the transport")
        let failure = RecordingLogger(); failure.failBlock = true
        do { _ = try await SensorClient(transportFactory: { failure }).download(); throw CheckFailed(message: "Failed recording transfer accepted") }
        catch TR7Error.timeout { }
        try check(failure.closed, "Download failure closes the transport")

        let cancelled = RecordingLogger()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SensorClient(transportFactory: { cancelled }).download()
        }
        do { _ = try await task.value; throw CheckFailed(message: "Cancelled download accepted") }
        catch is CancellationError { }
        try check(cancelled.commands.isEmpty, "Pre-cancelled download does not communicate")
        for cancelAt in [1, 2] {
            let interrupted = RecordingLogger()
            let interruptedTask = Task {
                try await SensorClient(transportFactory: { interrupted }).download { done, _ in
                    if done == cancelAt { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            do {
                _ = try await interruptedTask.value
                throw CheckFailed(message: "Interrupted download accepted")
            } catch is CancellationError { }
            try check(interrupted.closed && interrupted.commands.filter { $0.command == 0x41 }.count == cancelAt, "Cancellation during or after data transfer closes the transport")
        }
    }

    static func recordedDataChecks() throws {
        // Independent recording: 60-second interval, four pairs, ending at Unix 1700000180.
        var metadata = Data(repeating: 0, count: 128)
        metadata[0] = 60; metadata[30] = 0x0D; metadata[31] = 0xD0
        metadata.replaceSubrange(74..<78, with: [0xB4, 0xF1, 0x53, 0x65])
        metadata[112] = 4
        let raw = Data([0x4C, 0x04, 0xDC, 0x05, 0x00, 0xF0, 0x00, 0xF0,
                        0xB0, 0x04, 0xD0, 0x07, 0x14, 0x05, 0xAC, 0x0D])
        let data = try DownloadedData(metadata: metadata, samples: raw).validated()
        let rows = data.readings
        try check(rows.map(\.id) == [1, 2, 3, 4], "Recorded sample identifiers")
        try check(rows.map { $0.date?.timeIntervalSince1970 } == [1700000000, 1700000060, 1700000120, 1700000180], "Recorded timestamps follow the interval and last timestamp")
        try check(rows[0].channel1 == 10 && rows[0].channel2 == 50 && rows[1].channel1 == nil && rows[1].channel2 == nil, "Recorded measurements and missing values")

        let selected = data.readings(in: Date(timeIntervalSince1970: 1700000060)...Date(timeIntervalSince1970: 1700000120))
        try check(selected.map(\.id) == [2, 3], "Date filtering includes both boundaries and preserves identifiers")
        let one = data.readings(in: Date(timeIntervalSince1970: 1700000120)...Date(timeIntervalSince1970: 1700000120))
        try check(one.count == 1 && one[0].raw1 == 1200 && one[0].channel1 == 20, "Single-time selection preserves raw readings")
        try check(data.readings(in: Date(timeIntervalSince1970: 1)...Date(timeIntervalSince1970: 2)).isEmpty, "Date filtering outside the recording")
        let csv = data.csv(for: selected)
        try check(csv.components(separatedBy: "\n").count == 4 && csv.contains("2,2023-11-14T22:14:20Z,,,61440,61440\n") && csv.contains("3,2023-11-14T22:15:20Z,20.0,100.0,1200,2000\n"), "Selected CSV contains only selected original rows and UTC times")
        try check(data.csv.components(separatedBy: "\n").count == 6, "Unfiltered CSV remains complete")
        let report = data.htmlReport(for: one)
        try check(report.contains("1 paired readings of 4 downloaded") && report.contains("Minimum 20.0 · Maximum 20.0 · Mean 20.0") && !report.contains("Mean 10.0"), "Selected report count and statistics")
        try check(data.htmlReport.components(separatedBy: "<polyline").count == 5, "Report graph does not connect missing measurements")
        try check(data.htmlReport(for: []).contains("No valid measurements.") && data.csv(for: []).components(separatedBy: "\n").count == 2, "Empty exports contain no invented measurements")

        var unknown = metadata
        unknown.replaceSubrange(74..<78, with: [0, 0, 0, 0])
        let timeless = DownloadedData(metadata: unknown, samples: raw)
        try check(timeless.readings(in: Date.distantPast...Date.distantFuture).isEmpty && timeless.csv.contains("1,,10.0,50.0"), "Unknown timestamps remain exportable and do not match date filters")
        unknown.replaceSubrange(74..<78, with: [255, 255, 255, 255])
        try check(DownloadedData(metadata: unknown, samples: raw).lastSampleDate == nil, "Unavailable timestamp sentinel")
        try check(data.metadata == metadata && data.samples == raw, "Filtering and reports preserve the downloaded archive")
    }
}
