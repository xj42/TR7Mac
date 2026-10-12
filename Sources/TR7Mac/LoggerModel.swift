import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TR7Core

struct BluetoothLoggerChoice: Identifiable {
    let id: UUID
    let name: String
    let serial: String?
    let rssi: Int?
}

@MainActor final class LoggerModel: ObservableObject {
    @Published var devices: [USBLogger] = []
    @Published var selectedPath = ""
    @Published var connectionKind = "USB"
    @Published var passcode = ""
    let bluetooth = BluetoothDiscovery()
    private let bluetoothRegistry = BluetoothRegistry()
    @Published var registeredBluetoothLoggers: [RegisteredBluetoothLogger] = []
    @Published var full: FullSettings?
    var settings: LoggerSettings? { full?.basic }
    @Published var address = ""
    @Published var port = "443"
    @Published var destinationMode: UInt16 = 7
    @Published var regularUpload = true
    @Published var interval = 600
    @Published var clockDate = Date()
    @Published var clockZone = "UTC"
    @Published var timezoneMinutes = 600
    @Published var daylightSaving = false
    @Published var daylightMinutes = 60
    @Published var sntpEnabled = true
    @Published var sntpServer = "time.google.com"
    @Published var names = LoggerNames()
    @Published var networkDrafts: [NetworkProfile] = []
    @Published var networkIndex = 0
    @Published var accessPoints: [WiFiAccessPoint] = []
    @Published var timers: [MaxMinTimer] = []
    @Published var timerIndex = 0
    @Published var warnings: WarningSettings?
    @Published var calibrationDraft = CalibrationDraft()
    @Published var calibrationHistory: [CalibrationHistoryEntry] = []
    @Published var certificateInfo: CertificateInfo?
    @Published var connectionTestEvents: [ConnectionTestEvent] = []
    @Published var recordingInterval = 15
    @Published var endless = true
    @Published var programmedStart = false
    @Published var startDate = Date().addingTimeInterval(3600)
    @Published var readings: CurrentReadings?
    @Published var readingsAt: Date?
    @Published var monitoring = false
    @Published var fahrenheit = false
    @Published var bluetoothEnabled = true
    @Published var newPasscode = ""
    @Published var downloaded: DownloadedData?
    @Published var downloadCount = 0
    @Published var downloadProgress = 0.0
    @Published var logs: [OperationLogEntry] = []
    @Published var certificateDescription = "Read the certificate information from the logger."
    @Published var busy = false
    @Published var failed = false
    @Published var message = "Connect a logger, then read its settings."
    @Published var pending: Pending?
    private var client: SensorClient?, loadedPath: String?, operationTask: Task<Void, Never>?
    enum Pending: String, Identifiable {
        case destination, interval, uploadsOff, connectionTest, clock, time, names, network, warnings, timer, start, stop, alarm, maxmin, unit, bluetooth, passcode, reset, calibrationReset, calibration
        var id: String { rawValue }
    }
    init() { reloadBluetoothRegistrations(); discover(); if devices.isEmpty { connectionKind = "Bluetooth" } }
    var selectionMatchesConnection: Bool {
        switch connectionKind {
        case "USB": return devices.contains { $0.path == selectedPath }
        case "Bluetooth":
            guard selectedPath.hasPrefix("ble:"), let id = UUID(uuidString: String(selectedPath.dropFirst(4))) else { return false }
            return bluetoothLoggerChoices.contains { $0.id == id }
        default: return false
        }
    }
    var canEdit: Bool { full != nil && loadedPath == selectedPath && selectionMatchesConnection && !busy }
    var timeZone: TimeZone { clockZone == "UTC" ? TimeZone(secondsFromGMT: 0)! : .current }
    var destinationChanged: Bool { guard let s = settings else { return false }; return address != s.address || Int(port) != Int(s.port) || destinationMode != s.destinationMode }
    var intervalChanged: Bool { guard let s = settings else { return false }; return regularUpload != s.uploadEnabled || interval != Int(s.intervalSeconds) }
    var warningsChanged: Bool { guard let warnings, let original = full?.responses["warnings"] else { return false }; return (try? warnings.encoded()) != original }
    var pendingDescription: String {
        let name = settings?.name ?? "logger"
        switch pending {
        case .destination: return "Set \(name)'s upload destination to \(destinationMode == 0 ? "https" : "http")://\(address):\(port)?"
        case .interval: return regularUpload ? "Set regular uploads to every \(interval / 60) minutes? Scheduled uploads will be preserved." : "Disable regular uploads? Existing scheduled uploads will remain enabled if configured."
        case .uploadsOff: return "Turn OFF all automatic uploads on \(name)? Both regular and scheduled uploads will be disabled. Stored scheduled times will be retained."
        case .connectionTest: return "Test Wi-Fi profile \(networkIndex + 1) using the settings currently saved on \(name)? This asks the logger to communicate with its saved server and may upload recorded data. Save edited network and upload settings first."
        case .clock: return "Set \(name)'s internal UTC clock to \(LoggerClock(date: clockDate, timeZone: timeZone).description)? Timezone settings will be preserved."
        case .time: return "Save timezone UTC\(timezoneMinutes >= 0 ? "+" : "")\(Double(timezoneMinutes) / 60), daylight saving and time synchronization settings?"
        case .names: return "Save device, group and channel names to \(name)?"
        case .network: return "Save Wi-Fi profile \(networkIndex + 1) (\(networkDrafts[networkIndex].ssid)), IP and proxy settings? Incorrect settings can interrupt automatic uploads."
        case .warnings:
            guard let warnings else { return "Warning settings are unavailable." }
            func limit(_ enabled: Bool, _ value: Double, _ unit: String) -> String { enabled ? String(format: "%.1f %@", value, unit) : "Off" }
            return """
            Save warning settings to \(name)?

            Channel 1: upper \(limit(warnings.upper1Enabled, warnings.upper1, "°C")), lower \(limit(warnings.lower1Enabled, warnings.lower1, "°C")), sensor \(warnings.sensor1Enabled ? "On" : "Off"), judgment \(warnings.delay1) seconds.
            Channel 2: upper \(limit(warnings.upper2Enabled, warnings.upper2, "%RH")), lower \(limit(warnings.lower2Enabled, warnings.lower2, "%RH")), sensor \(warnings.sensor2Enabled ? "On" : "Off"), judgment \(warnings.delay2) seconds.
            Battery warning: \(warnings.batteryEnabled ? "On" : "Off").

            Changing warning settings clears an active ALM warning.
            """
        case .timer: return "Save daily max/min reset timer \(timerIndex + 1)?"
        case .start: return "Start a new recording with a \(recordingInterval)-second interval in \(endless ? "endless" : "one-time") mode\(programmedStart ? " at \(startDate.formatted())" : " immediately")? ALL previously recorded data on the logger will be erased. Download it first if needed."
        case .stop: return "Stop recording on \(name)? Stored readings will remain available for download."
        case .alarm: return "Clear the ALM indicator on \(name)? Warning settings will be preserved."
        case .maxmin: return "Clear the displayed maximum and minimum values on \(name)?"
        case .unit: return "Set the logger's temperature display to \(fahrenheit ? "°F" : "°C")? Download exports use °C."
        case .bluetooth: return "\(bluetoothEnabled ? "Enable" : "Disable") Bluetooth on \(name)? USB is needed to re-enable Bluetooth if disabled."
        case .passcode: return "Set a new six-digit Bluetooth passcode? Keep a copy; it will be needed for future Bluetooth connections."
        case .reset: return "Reset \(name) to factory settings? Recording, network, upload, names and sensor adjustment settings will be reset. Download any readings you need first."
        case .calibrationReset: return "Initialize both sensor adjustments to y = x? Measurements will no longer use existing correction coefficients."
        case .calibration:
            guard let raw = full?.responses["calibration"], let current = try? CalibrationSettings(raw),
                  let result = try? calibrationDraft.applying(to: current) else { return "Enter valid sensor adjustment points first." }
            return "Save sensor adjustments to \(name)? Channel 1: \(result.channels[0].equation). Channel 2: \(result.channels[1].equation). Recording must be stopped. These corrections compose with the existing adjustments."
        case nil: return ""
        }
    }

    func discover() {
        devices = USBLogger.discover()
        if connectionKind == "USB", !devices.contains(where: { $0.path == selectedPath }) { selectedPath = devices.first?.path ?? ""; clearLoaded() }
    }

    func changeConnection() {
        bluetooth.stop(); selectedPath = ""; passcode = ""; clearLoaded(); discover() }

    func reloadBluetoothRegistrations() { registeredBluetoothLoggers = bluetoothRegistry.list() }
    func registerSelectedBluetoothLogger() {
        guard connectionKind == "Bluetooth", selectedPath.hasPrefix("ble:"),
              let id = UUID(uuidString: String(selectedPath.dropFirst(4))) else { return }
        let name = bluetooth.devices.first(where: { $0.id == id })?.name ??
            registeredBluetoothLoggers.first(where: { $0.id == id })?.name ?? "TR7 Bluetooth logger"
        bluetoothRegistry.register(id: id, name: name); reloadBluetoothRegistrations()
        failed = false; message = "Registered \(name) for future Bluetooth connections."
    }
    func forgetSelectedBluetoothLogger() {
        guard connectionKind == "Bluetooth", selectedPath.hasPrefix("ble:"),
              let id = UUID(uuidString: String(selectedPath.dropFirst(4))) else { return }
        bluetoothRegistry.remove(id: id); reloadBluetoothRegistrations()
        failed = false; message = "Forgot the selected Bluetooth logger."
    }

    func selectBluetoothDevice() {
        guard connectionKind == "Bluetooth", !busy else { return }
        if !bluetoothLoggerChoices.contains(where: { "ble:" + $0.id.uuidString == selectedPath }) {
            selectedPath = bluetoothLoggerChoices.first.map { "ble:" + $0.id.uuidString } ?? ""
        }
    }
    var bluetoothLoggerChoices: [BluetoothLoggerChoice] {
        var seen = Set<UUID>()
        let discovered = bluetooth.devices.compactMap { logger -> BluetoothLoggerChoice? in
            guard seen.insert(logger.id).inserted else { return nil }
            return BluetoothLoggerChoice(id: logger.id, name: logger.name, serial: logger.serial, rssi: logger.rssi)
        }
        let saved = registeredBluetoothLoggers.compactMap { logger -> BluetoothLoggerChoice? in
            guard seen.insert(logger.id).inserted else { return nil }
            return BluetoothLoggerChoice(id: logger.id, name: logger.name, serial: nil, rssi: nil)
        }
        return discovered + saved
    }

    func clearLoaded() { full = nil; readings = nil; readingsAt = nil; client = nil; loadedPath = nil; failed = false; monitoring = false; networkDrafts = []; accessPoints = []; timers = []; warnings = nil; calibrationDraft = CalibrationDraft(); calibrationHistory = []; certificateInfo = nil; connectionTestEvents = []; logs = []; certificateDescription = "Read the certificate information from the logger." }

    func load() {
        guard !busy else { return }
        guard selectionMatchesConnection else {
            show(TR7Error.invalid("Select a logger for the chosen connection before reading settings.")); return
        }
        let path = selectedPath, connection: SensorClient
        if connectionKind == "Bluetooth", let identifier = UUID(uuidString: String(path.dropFirst(4))) {
            do { _ = try BluetoothProtocol.unlock(passcode: passcode) } catch { show(error); return }
            let code = passcode; bluetooth.stop()
            connection = SensorClient(transportFactory: { try BluetoothTransport(identifier: identifier, passcode: code) })
        } else if connectionKind == "USB" { connection = SensorClient(path: path) }
        else { show(TR7Error.invalid("Select a logger for the chosen connection before reading settings.")); return }
        clearLoaded(); busy = true; failed = false; message = "Reading logger settings and current measurements…"
        operationTask = Task {
            do {
                let snapshot = try await connection.readFull()
                guard selectedPath == path else { busy = false; return }
                client = connection; loadedPath = path; adopt(snapshot)
                message = "Loaded \(snapshot.basic.name).\(snapshot.unavailable.isEmpty ? "" : " Some features are unavailable on this logger.")"
            } catch { show(error) }
            busy = false
        }
    }

    private func adopt(_ snapshot: FullSettings) {
        full = snapshot
        let s = snapshot.basic
        address = s.address; port = String(s.port); destinationMode = s.destinationMode
        regularUpload = s.uploadEnabled; interval = Int(s.intervalSeconds)
        let time = TimeConfiguration(s)
        timezoneMinutes = time.offsetMinutes; daylightSaving = time.daylightSaving; daylightMinutes = time.daylightMinutes
        sntpEnabled = time.sntpEnabled; sntpServer = time.server; clockDate = s.clock.comparisonDate
        names = snapshot.names ?? LoggerNames()
        networkDrafts = (2...4).compactMap { snapshot.pages[$0].flatMap { try? NetworkProfile($0) } }; networkIndex = 0
        warnings = snapshot.responses["warnings"].flatMap { try? WarningSettings($0) }
        calibrationDraft = CalibrationDraft()
        if let raw = snapshot.responses["resetTimers"], raw.count == 12 { timers = [try? MaxMinTimer(Data(raw.prefix(6))), try? MaxMinTimer(Data(raw.suffix(6)))].compactMap { $0 } }; timerIndex = 0
        if let recording = snapshot.recording { recordingInterval = recording.interval; endless = recording.endless }
        readings = snapshot.responses["current"].flatMap { try? CurrentReadings($0) }; readingsAt = Date()
    }

    func confirm() {
        guard let action = pending, let client, let expected = full, canEdit else { pending = nil; return }
        let targetAddress = address, targetPort = Int(port) ?? 0, targetMode = destinationMode
        let targetInterval = interval, targetEnabled = regularUpload, targetNames = names, targetWarnings = warnings
        let profile = networkDrafts.indices.contains(networkIndex) ? networkDrafts[networkIndex] : nil, profileIndex = networkIndex
        let timer = timers.indices.contains(timerIndex) ? timers[timerIndex] : nil, timerChannel = timerIndex + 1
        let clock = LoggerClock(date: clockDate, timeZone: timeZone)
        var time = TimeConfiguration(expected.basic); time.offsetMinutes = timezoneMinutes; time.daylightSaving = daylightSaving; time.daylightMinutes = daylightMinutes; time.sntpEnabled = sntpEnabled; time.server = sntpServer
        let recInterval = recordingInterval, recEndless = endless, recStart = programmedStart ? startDate : nil
        let unit = fahrenheit, bleEnabled = bluetoothEnabled, code = newPasscode
        let adjustment = calibrationDraft
        pending = nil; busy = true; failed = false; monitoring = false; message = "Applying the confirmed change…"
        operationTask = Task {
            do {
                var networkVerified = false
                switch action {
                case .destination: _ = try await client.setDestination(address: targetAddress, port: targetPort, mode: targetMode, expected: expected.basic)
                case .interval: _ = try await client.setInterval(seconds: targetInterval, enabled: targetEnabled, expected: expected.basic)
                case .uploadsOff: _ = try await client.setUploadsOff(expected: expected.basic)
                case .connectionTest:
                    connectionTestEvents = []
                    let events = try await client.testConnection(profile: profileIndex + 1) { event in
                        Task { @MainActor in self.connectionTestEvents.append(event) }
                    }
                    connectionTestEvents = events
                    let success = events.last?.succeeded == true
                    failed = !success
                    message = success ? "The logger reports a successful connection test." : "Connection test failed: \(events.last?.description ?? "unknown result")."
                    busy = false; return
                case .clock: _ = try await client.setClock(clock)
                case .time: try await client.setTimeConfiguration(time, expected: expected.basic)
                case .names:
                    guard let old = expected.names else { throw TR7Error.invalid("Names are unavailable on this logger.") }
                    try await client.setNames(targetNames, expected: old)
                case .network:
                    guard let profile, let old = expected.pages[profileIndex + 2] else { throw TR7Error.invalid("Network profile unavailable.") }
                    try await client.setNetwork(profile, number: profileIndex + 1, expected: old)
                    networkVerified = true
                case .warnings:
                    guard let targetWarnings, let old = expected.responses["warnings"] else { throw TR7Error.invalid("Warning settings unavailable.") }
                    try await client.setWarnings(targetWarnings, expected: old)
                case .timer:
                    guard let timer, let old = expected.responses["resetTimers"] else { throw TR7Error.invalid("Reset timers unavailable.") }
                    try await client.setResetTimer(timer, channel: timerChannel, expected: old)
                case .start:
                    guard let old = expected.recording else { throw TR7Error.invalid("Recording settings unavailable.") }
                    try await client.startRecording(old, interval: recInterval, endless: recEndless, start: recStart)
                case .stop: try await client.perform(.stopRecording)
                case .alarm: try await client.perform(.clearAlarm)
                case .maxmin: try await client.perform(.clearMaxMin)
                case .unit: try await client.setTemperatureUnit(fahrenheit: unit)
                case .bluetooth: try await client.setBluetoothEnabled(bleEnabled)
                case .passcode: try await client.setPasscode(code)
                case .calibrationReset: try await client.initializeCalibration(expected: expected.responses["calibration"] ?? Data())
                case .calibration:
                    _ = try await client.setCalibration(adjustment, expected: expected.responses["calibration"] ?? Data())
                case .reset:
                    try await client.perform(.factoryReset); clearLoaded(); message = "Factory reset acknowledged. Read the logger again."; busy = false; return
                }
                if action == .passcode && connectionKind == "Bluetooth" {
                    clearLoaded(); passcode = code; newPasscode = ""; message = "Passcode command acknowledged. Read the logger again using the new passcode."; busy = false; return
                }
                do {
                    let result = try await client.readFull(); adopt(result)
                    message = "Change acknowledged; refreshed \(result.basic.name)."
                } catch {
                    guard networkVerified else { throw error }
                    clearLoaded()
                    failed = true
                    message = "Wi-Fi profile saved and verified, but refreshing the screen failed: \(error.localizedDescription) Read Settings again to reload the logger."
                    busy = false
                    return
                }
                newPasscode = ""
            } catch is CancellationError { message = "Operation cancelled. Read the logger again to check its current state." }
            catch { if action != .connectionTest { clearLoaded() }; show(error) }
            busy = false
        }
    }
    func refreshCurrent() {
        guard canEdit, let client else { return }; busy = true
        operationTask = Task {
            do { readings = try CurrentReadings(await client.readCurrent()); readingsAt = Date(); failed = false; message = "Current measurements updated." }
            catch { monitoring = false; show(error) }
            busy = false
        }
    }
    func scanAccessPoints() {
        guard canEdit, let client else { return }
        busy = true; failed = false; accessPoints = []; message = "Scanning for nearby Wi-Fi networks…"
        operationTask = Task {
            do {
                let report = try await client.scanAccessPoints()
                accessPoints = report.accessPoints
                message = "Found \(report.accessPoints.count) nearby Wi-Fi network\(report.accessPoints.count == 1 ? "" : "s")."
            } catch is CancellationError { message = "Wi-Fi scan cancelled." }
            catch { show(error) }
            busy = false
        }
    }
    func download(periodSeconds: Int? = nil) {
        guard canEdit, let client else { return }; busy = true; failed = false; monitoring = false; downloadProgress = 0; message = "Downloading stored readings…"
        let count = periodSeconds == nil ? downloadCount : 0
        operationTask = Task {
            do {
                let result = try await client.download(count: count, periodSeconds: periodSeconds) { done, total in
                    Task { @MainActor in self.downloadProgress = total == 0 ? 1 : Double(done) / Double(total) }
                }
                downloaded = try result.validated(); message = "Downloaded \(result.count) readings. Stored data remains on the logger."
            } catch is CancellationError { message = "Download cancelled. The previous download is still available." }
            catch { show(error) }
            busy = false
        }
    }
    func cancel() { operationTask?.cancel() }
    func readCalibrationHistory() {
        guard canEdit, let client else { return }; busy = true; failed = false
        operationTask = Task {
            do { calibrationHistory = try await client.readCalibrationHistory(); message = "Read \(calibrationHistory.count) sensor adjustment history entries." }
            catch { show(error) }; busy = false
        }
    }
    func readLogs() {
        guard canEdit, let client else { return }; busy = true; failed = false
        operationTask = Task {
            do { logs = try OperationLogEntry.decode(await client.readLogs()); message = "Read \(logs.count) operation log entries." }
            catch { show(error) }; busy = false
        }
    }
    func readCertificates() {
        guard canEdit, connectionKind == "USB", let client else { return }; busy = true; failed = false
        operationTask = Task {
            do { certificateInfo = try await client.readCertificate(usb: true); message = "Certificate information read." }
            catch { certificateInfo = nil; show(error) }; busy = false
        }
    }
    func installCertificate(_ certificate: RootCertificate) {
        guard canEdit, connectionKind == "USB", let client, let expected = certificateInfo else { return }
        busy = true; failed = false; monitoring = false; message = "Installing root certificate…"
        operationTask = Task {
            do { certificateInfo = try await client.installCertificate(certificate, expected: expected, usb: true); message = "Certificate transferred and metadata verified. Run a connection test to check HTTPS delivery." }
            catch { certificateInfo = nil; show(error) }; busy = false
        }
    }
    func deleteCertificate() {
        guard canEdit, connectionKind == "USB", let client, let expected = certificateInfo else { return }
        busy = true; failed = false; monitoring = false
        operationTask = Task {
            do { certificateInfo = try await client.deleteCertificate(expected: expected, usb: true); message = "Custom root certificate deleted; metadata verified." }
            catch { certificateInfo = nil; show(error) }; busy = false
        }
    }
    func exportSettings() {
        guard let full else { return }
        do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            save(try encoder.encode(SettingsSummary(full)), name: "TR7-settings.json", type: .json)
        } catch { show(error) }
    }
    func exportData(archive: Bool) {
        guard let downloaded else { return }
        do {
            if archive { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted]; encoder.dateEncodingStrategy = .iso8601; save(try encoder.encode(downloaded), name: "TR7-recordings.json", type: .json) }
            else { save(Data(downloaded.csv.utf8), name: "TR7-recordings.csv", type: .commaSeparatedText) }
        } catch { show(error) }
    }
    func exportLogs() { save(Data(OperationLogEntry.csv(logs).utf8), name: "TR7-operation-log.csv", type: .commaSeparatedText) }
    func importData() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 2_000_000 else { throw TR7Error.invalid("The recording archive is too large.") }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            downloaded = try decoder.decode(DownloadedData.self, from: Data(contentsOf: url)).validated()
            failed = false; message = "Opened recording archive."
        } catch { show(error) }
    }
    func save(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = name; panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url, options: .atomic); failed = false; message = "Saved \(url.lastPathComponent)." } catch { show(error) }
    }
    private func show(_ error: Error) { failed = true; message = error.localizedDescription }
}
