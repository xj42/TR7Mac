import Foundation
import TR7Core

private final class CalibrationLogger: LoggerTransport {
    var calibration = Data([1, 2, 3, 4, 0xE8, 3, 0, 0, 0xE8, 3, 0, 0])
    var history = Data(repeating: 0, count: 80)
    var recording = false, ignoreWrite = false, ignoreHistoryWrite = false, closed = false
    var commands: [Packet] = []
    func exchange(_ packet: Packet) throws -> Data {
        commands.append(packet)
        switch packet.command {
        case 0x55:
            var result = Data(repeating: 0, count: 128); result[2] = recording ? 2 : 0; return result
        case 0x53: return calibration
        case 0x52: if !ignoreWrite { calibration = packet.payload }; return Data()
        case 0x60: return history
        case 0x61: if !ignoreHistoryWrite { history = packet.payload }; return Data()
        default: throw CheckFailed(message: "Unexpected calibration command")
        }
    }
    func close() { closed = true }
}

extension Checks {
    static func calibrationChecks() async throws {
        let original = Data([1, 2, 3, 4, 0xE8, 3, 0, 0, 0xE8, 3, 0, 0])
        let current = try CalibrationSettings(original)
        try check(current.channels.allSatisfy(\.isIdentity), "Calibration identity decoding")
        try check(try CalibrationSettings(Data([0, 0, 0, 0, 0x1A, 4, 0x38, 0xFF, 0xE8, 3, 0, 0])).channels[0].offset == -200, "Calibration offset is signed little endian")
        var draft = CalibrationDraft(); draft.channels[0].enabled = true
        draft.channels[0].before1 = 10.2; draft.channels[0].after1 = 10
        let epoch = Date(timeIntervalSince1970: 0x04030201)
        let proposed = try draft.applying(to: current, date: epoch)
        try check(proposed.raw == Data([1, 2, 3, 4, 0xE8, 3, 0x38, 0xFF, 0xE8, 3, 0, 0]), "One-point independent calibration byte vector; unchanged CH2 preserved")
        var two = draft; two.channels[0].method = .twoPoint
        two.channels[0].before1 = 0.2; two.channels[0].after1 = 0
        two.channels[0].before2 = 9.6; two.channels[0].after2 = 10
        let twoResult = try two.applying(to: current, date: epoch)
        try check(twoResult.raw == Data([1, 2, 3, 4, 0x28, 4, 0x2A, 0xFF, 0xE8, 3, 0, 0]), "Two-point slope rounds before offset; signed offset vector")
        let adjusted = try CalibrationSettings(Data([1, 2, 3, 4, 0x4C, 4, 0xC8, 0, 0xE8, 3, 0, 0]))
        try check(try two.applying(to: adjusted).channels[0] == CalibrationCoefficients(slope: 1170, offset: -1), "Existing calibration composes with correction")
        var invalid = draft; invalid.channels[0].after1 = 20
        try rejects("Calibration correction beyond five accepted") { _ = try invalid.applying(to: current) }
        invalid = two; invalid.channels[0].before2 = invalid.channels[0].before1
        try rejects("Duplicate two-point inputs accepted") { _ = try invalid.applying(to: current) }
        invalid = draft; invalid.channels[0].before1 = .nan
        try rejects("Nonfinite calibration input accepted") { _ = try invalid.applying(to: current) }
        invalid = draft; invalid.channels[0].after1 = 10.01
        try rejects("Calibration sub-resolution input accepted") { _ = try invalid.applying(to: current) }
        try rejects("No adjustment channel accepted") { _ = try CalibrationDraft().applying(to: current) }

        // Literal vendor file: marker and two Windows C structures, independent of encoder.
        var file = Data("TR7WF-Adjustment\n".utf8)
        file.append(Data([1, 0, 0, 0, 0, 0, 0, 0]))
        for text in ["10.2", "10.0", "10.0", "10.0"] {
            let bytes = Data(text.utf8); file.append(bytes); file.append(Data(repeating: 0, count: 8 - bytes.count))
        }
        file.append(Data(repeating: 0, count: 8))
        for text in ["0.0", "10.0", "0.0", "10.0"] {
            let bytes = Data(text.utf8); file.append(bytes); file.append(Data(repeating: 0, count: 8 - bytes.count))
        }
        try check(try CalibrationDraft(windowsFile: file) == draft, "Vendor adjustment file independent fixture")
        try check(try draft.windowsFile() == file, "Vendor adjustment file export matches byte layout")
        try rejects("Truncated calibration file accepted") { _ = try CalibrationDraft(windowsFile: file.dropLast()) }
        var corrupt = file; corrupt[0] = 0
        try rejects("Invalid calibration file marker accepted") { _ = try CalibrationDraft(windowsFile: corrupt) }

        let logger = CalibrationLogger(), client = SensorClient(transportFactory: { logger })
        _ = try await client.setCalibration(draft, expected: original, date: epoch)
        try check(logger.commands.map(\.command) == [0x55, 0x53, 0x60, 0x52, 0x53, 0x61, 0x60], "Calibration reads fresh recording state and history, verifies coefficients/history")
        try check(logger.closed, "Calibration transport closes")
        let history = try await client.readCalibrationHistory()
        try check(history.count == 1 && history[0].channel == 1 && history[0].before1 == 10.2 && history[0].after1 == 10, "Vendor device adjustment history decoded")
        try check(logger.history.prefix(15) == Data([1, 1, 1, 2, 3, 4, 102, 0, 0, 0, 100, 0, 0, 0, 0]), "History independent literal byte vector")
        try check(logger.history.subdata(in: 60..<76) == Data([0, 0, 0, 0, 0, 0x40, 0x8F, 0x40, 0, 0, 0, 0, 0, 0x40, 0x8F, 0x40]), "History uses scaled IEEE754 slopes")
        var historyBlock = logger.history; historyBlock.replaceSubrange(76..<80, with: Data([0xA1, 0xB2, 0xC3, 0xD4]))
        for _ in 0..<5 { historyBlock = try draft.historyBlock(from: historyBlock, settings: proposed) }
        try check(try CalibrationHistoryEntry.decode(historyBlock).count == 4 && historyBlock.suffix(4) == Data([0xA1, 0xB2, 0xC3, 0xD4]), "Adjustment history retains last four and preserves reserved bytes")
        logger.commands = []; logger.recording = true
        do { _ = try await client.setCalibration(draft, expected: logger.calibration); throw CheckFailed(message: "Calibration changed while recording") }
        catch is CheckFailed { throw CheckFailed(message: "Calibration changed while recording") }
        catch {}
        try check(logger.commands.map(\.command) == [0x55], "Recording calibration rejection occurs before writes")
        logger.recording = false; logger.commands = []
        do { _ = try await client.setCalibration(draft, expected: original); throw CheckFailed(message: "Stale calibration accepted") }
        catch is CheckFailed { throw CheckFailed(message: "Stale calibration accepted") }
        catch {}
        try check(!logger.commands.contains(where: { $0.command == 0x52 || $0.command == 0x61 }), "Stale calibration snapshot cannot write")
        logger.ignoreWrite = true; logger.commands = []
        do { _ = try await client.setCalibration(draft, expected: logger.calibration); throw CheckFailed(message: "Calibration readback mismatch accepted") }
        catch is CheckFailed { throw CheckFailed(message: "Calibration readback mismatch accepted") }
        catch {}
        try check(!logger.commands.contains(where: { $0.command == 0x61 }), "Calibration mismatch prevents history write")
        logger.ignoreWrite = false; logger.ignoreHistoryWrite = true
        do { _ = try await client.setCalibration(draft, expected: logger.calibration); throw CheckFailed(message: "History mismatch accepted") }
        catch is CheckFailed { throw CheckFailed(message: "History mismatch accepted") }
        catch { try check(error.localizedDescription.contains("coefficients were saved"), "History failure reports partial-success boundary") }
        logger.ignoreHistoryWrite = false
        try await client.initializeCalibrationWithHistory(expected: logger.calibration, date: epoch)
        try check(try CalibrationSettings(logger.calibration).channels.allSatisfy(\.isIdentity), "Initialization restores both channel identities")
        try check(try CalibrationHistoryEntry.decode(logger.history).last?.method == 3, "Initialization is recorded in device history")
    }
}
