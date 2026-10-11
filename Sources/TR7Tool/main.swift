import Foundation
import TR7Core

@main struct Tool {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())

            guard let command = arguments.first else { usage(); return }

            if command == "scan" {
                for logger in USBLogger.discover() { print("\(logger.path)\t\(logger.name)\t\(logger.serial ?? "")") }
                return
            }

            guard arguments.count >= 2 else { throw TR7Error.invalid("A USB device path is required.") }
            let client = SensorClient(path: arguments[1])

            if command == "verify" {
                let succeeded = await verify(client: client,
                                             writes: arguments.contains("--writes"),
                                             connectionTest: arguments.contains("--connection-test"))
                if !succeeded { exit(1) }
                return
            }
            if command == "wifi-scan" {
                let report = try await client.scanAccessPoints()
                print(String(data: report.raw, encoding: .utf8) ?? report.raw.hex)
                return
            }
            if command == "certificate-install" {
                guard arguments.count == 3 else { throw TR7Error.invalid("Usage: tr7 certificate-install DEVICE FILE") }
                let url = URL(fileURLWithPath: arguments[2])
                let certificate = try RootCertificate(data: Data(contentsOf: url), filename: url.lastPathComponent)
                let expected = try await client.readCertificate(usb: true)
                let installed = try await client.installCertificate(certificate, expected: expected, usb: true)
                print("Installed \(installed.filename); SHA-256 \(certificate.fingerprint)")
                return
            }
            if command == "certificate-delete" {
                guard arguments.count == 2 else { throw TR7Error.invalid("Usage: tr7 certificate-delete DEVICE") }
                let expected = try await client.readCertificate(usb: true)
                guard expected.isInstalled else { throw TR7Error.invalid("No custom root certificate is installed.") }
                _ = try await client.deleteCertificate(expected: expected, usb: true)
                print("Deleted \(expected.filename)")
                return
            }
            let result: LoggerSettings

            switch command {
            case "read":
                if let index = arguments.firstIndex(of: "--download") {
                    guard arguments.count > index + 1, let count = Int(arguments[index + 1]) else { throw TR7Error.invalid("Use --download COUNT (0 for all).") }
                    let data = try await client.download(count: count)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                    if let output = arguments.firstIndex(of: "--output"), arguments.count > output + 1 {
                        try encoder.encode(data).write(to: URL(fileURLWithPath: arguments[output + 1]), options: .atomic)
                    }
                    print("Readings: \(data.count)\nMetadata: \(data.metadata.hex)\nFirst samples: \(data.samples.prefix(40).hex)")
                    return
                } else if arguments.contains("--logs") {
                    let bytes = try await client.readLogs()
                    print(bytes.hex)
                    return
                } else if arguments.contains("--certificates") {
                    for bytes in try await client.readCertificateInfo() { print(bytes.hex) }
                    return
                } else if arguments.contains("--full") {
                    let full = try await client.readFull()
                    let data = full.responses.mapValues { $0.hex }
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                    struct Snapshot: Encodable { let settings: SettingsSummary; let responses: [String: String]; let unavailable: [String: String] }
                    print(String(data: try encoder.encode(Snapshot(settings: SettingsSummary(full), responses: data, unavailable: full.unavailable)), encoding: .utf8)!)
                    return
                }
                result = try await client.read()
            case "destination":
                guard arguments.count == 4, let port = Int(arguments[3]) else {
                    throw TR7Error.invalid("Usage: tr7 destination DEVICE HOST PORT")
                }
                let expected = try await client.read()
                result = try await client.setDestination(address: arguments[2], port: port, expected: expected)
            case "interval":
                guard arguments.count == 3, let seconds = Int(arguments[2]) else {
                     throw TR7Error.invalid("Usage: tr7 interval DEVICE SECONDS (0 disables regular upload)")
                }
                let expected = try await client.read()
                result = try await client.setInterval(seconds: seconds == 0 ? max(1, Int(expected.intervalSeconds)) : seconds,
                                                       enabled: seconds != 0, expected: expected)
            case "clock":
                guard arguments.count == 3
                else {
                    throw TR7Error.invalid("Usage: tr7 clock DEVICE YYYY-MM-DDTHH:MM:SS (literal logger calendar fields)")
                }
                let parser = DateFormatter();
                parser.locale = Locale(identifier: "en_US_POSIX")
                parser.timeZone = TimeZone(secondsFromGMT: 0);
                parser.dateFormat = "yyyy-MM-dd'T'HH:mm:ss";
                parser.isLenient = false
                guard let date = parser.date(from: arguments[2]) else {
                    throw TR7Error.invalid("Enter a valid calendar timestamp.")
                }
                result = try await client.setClock(LoggerClock(date: date, timeZone: TimeZone(secondsFromGMT: 0)!))
            default: throw TR7Error.invalid("Unknown command: \(command)")
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            print(String(data: try encoder.encode(result), encoding: .utf8)!)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1)
        }
    }
    static func usage() {
        print("""
        tr7 scan
        tr7 read DEVICE [--full | --logs | --certificates | --download COUNT [--output FILE]]
        tr7 destination DEVICE HOST PORT
        tr7 interval DEVICE SECONDS
        tr7 clock DEVICE YYYY-MM-DDTHH:MM:SS
        tr7 verify DEVICE [--writes] [--connection-test]
        tr7 wifi-scan DEVICE
        tr7 certificate-install DEVICE FILE
        tr7 certificate-delete DEVICE
        DEVICE is a /dev/cu.usbmodem… path. Interval 0 disables regular upload.
        Clock sends literal logger calendar fields; timezone settings are preserved.
        Verify performs all non-destructive reads. --writes rewrites the same settings
        with readback verification; --connection-test uses the saved Wi-Fi/server settings.
        """)
    }

    static func verify(client: SensorClient, writes: Bool, connectionTest: Bool) async -> Bool {
        var failed = false
        var snapshot: FullSettings?
        func check(_ name: String, _ action: () async throws -> String) async {
            do { print("PASS\t\(name)\t\(try await action())") }
            catch { failed = true; print("FAIL\t\(name)\t\(error.localizedDescription)") }
        }

        await check("full settings and live values") {
            let value = try await client.readFull(); snapshot = value
            let firmware = value.responses["firmware"].flatMap {
                String(data: $0.dropFirst(8).prefix { $0 != 0 && $0 != 255 }, encoding: .utf8)
            } ?? "unknown"
            let identity = value.names.map { ", group \($0.group), channels \($0.channel1) / \($0.channel2)" } ?? ""
            return "\(value.basic.name)\(identity), firmware \(firmware)"
        }
        await check("operation log") { "\(try await client.readLogs().count) bytes" }
        await check("recorded data") {
            let data = try await client.download(count: 100)
            _ = try data.validated()
            return "\(data.count) readings"
        }
        await check("adjustment history") { "\(try await client.readCalibrationHistory().count) entries" }
        await check("custom root certificate") {
            let value = try await client.readCertificate(usb: true)
            return value.isInstalled ? value.filename : "none installed"
        }

        if connectionTest {
            await check("network connection test") {
                let events = try await client.testConnection(profile: 1)
                guard events.last?.succeeded == true else { throw TR7Error.verification(events.last?.description ?? "no final result") }
                return events.map(\.description).joined(separator: "; ")
            }
        }

        if writes, let value = snapshot {
            await check("destination write/readback") {
                let current = try await client.read()
                _ = try await client.setDestination(address: current.address, port: Int(current.port), mode: current.destinationMode, expected: current)
                return "unchanged"
            }
            await check("upload interval write/readback") {
                let current = try await client.read()
                _ = try await client.setInterval(seconds: Int(current.intervalSeconds), enabled: current.uploadEnabled, expected: current)
                return "unchanged"
            }
            await check("timezone and SNTP write/readback") {
                let current = try await client.read()
                try await client.setTimeConfiguration(TimeConfiguration(current), expected: current)
                return "unchanged"
            }
            if let names = value.names {
                await check("names write/readback") { try await client.setNames(names, expected: names); return "unchanged" }
            }
            for page in 2...4 where value.pages[page] != nil {
                await check("Wi-Fi profile \(page - 1) write/readback") {
                    let raw = value.pages[page]!
                    let profile = try NetworkProfile(raw)
                    guard try profile.networkBlock() + profile.proxyBlock() == raw else {
                        throw TR7Error.invalid("round-trip encoding would change reserved bytes")
                    }
                    try await client.setNetwork(profile, number: page - 1, expected: raw)
                    return "unchanged"
                }
            }
            if let bytes = value.responses["warnings"] {
                await check("warnings write/readback") {
                    try await client.setWarnings(try WarningSettings(bytes), expected: bytes); return "unchanged"
                }
            }
            if let bytes = value.responses["resetTimers"], bytes.count == 12 {
                for channel in 1...2 {
                    await check("max/min timer channel \(channel) write/readback") {
                        let range = (channel - 1) * 6..<channel * 6
                        try await client.setResetTimer(try MaxMinTimer(Data(bytes[range])), channel: channel, expected: bytes)
                        return "unchanged"
                    }
                }
            }
            await check("clock write/readback") {
                _ = try await client.setClock(LoggerClock(date: Date(), timeZone: TimeZone(secondsFromGMT: 0)!))
                return "synchronized to computer UTC"
            }
        }
        return !failed
    }
}
