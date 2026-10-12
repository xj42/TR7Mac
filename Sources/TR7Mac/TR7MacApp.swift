import SwiftUI
import AppKit
import TR7Core

@main struct TR7MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = LoggerModel()
    var body: some Scene {
        WindowGroup { ContentView(model: model, bluetooth: model.bluetooth).frame(minWidth: 780, idealWidth: 920, minHeight: 640) }
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Page: String, CaseIterable {
    case monitor = "Monitor", data = "Recorded Data", recording = "Recording", upload = "Upload", network = "Network", clock = "Clock", device = "Device", warnings = "Warnings", calibration = "Adjustment", logs = "Operation Log", certificates = "Certificates"
    var symbol: String {
        switch self {
        case .monitor: return "waveform.path.ecg"
        case .data: return "chart.xyaxis.line"
        case .recording: return "record.circle"
        case .upload: return "arrow.up.circle"
        case .network: return "wifi"
        case .clock: return "clock"
        case .device: return "sensor.tag.radiowaves.forward"
        case .warnings: return "exclamationmark.triangle"
        case .calibration: return "slider.horizontal.3"
        case .logs: return "list.bullet.rectangle"
        case .certificates: return "lock.shield"
        }
    }
}
struct ContentView: View {
    @ObservedObject var model: LoggerModel
    @ObservedObject var bluetooth: BluetoothDiscovery
    @State private var page: Page = .monitor
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    var body: some View {
        VStack(spacing: 0) {
            connection.padding(16)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Page.allCases, id: \.self) { item in
                        Button { page = item } label: {
                            Label(item.rawValue, systemImage: item.symbol).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9).padding(.horizontal, 10)
                                .background(page == item ? Color.accentColor.opacity(0.15) : Color.clear).cornerRadius(6)
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    if let settings = model.settings { Text(settings.name).font(.headline); Text("Read \(settings.readAt, style: .time)").font(.caption).foregroundColor(.secondary) }
                    Button("Export Settings…") { model.exportSettings() }.disabled(!model.canEdit)
                }.padding(10).frame(width: 175).background(Color(NSColor.controlBackgroundColor))
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(page.rawValue).font(.title2.weight(.semibold))
                        detail
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(alignment: .top, spacing: 8) {
                if model.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: model.failed ? "exclamationmark.circle" : "info.circle").foregroundColor(model.failed ? .red : .secondary) }
                Text(model.message).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.padding(14)
        }
        .onChange(of: model.connectionKind) { _ in model.changeConnection() }
        .onChange(of: bluetooth.devices) { _ in model.selectBluetoothDevice() }
        .onChange(of: model.selectedPath) { _ in model.clearLoaded() }
        .onReceive(tick) { _ in if model.monitoring && model.canEdit && model.pending == nil { model.refreshCurrent() } }
        .sheet(item: $model.pending) { action in
            VStack(alignment: .leading, spacing: 18) {
                Text(action == .start || action == .reset ? "Confirm data-erasing action" : "Confirm logger change").font(.headline)
                Text(model.pendingDescription).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { model.pending = nil }.keyboardShortcut(.cancelAction)
                    Button("Confirm") { model.confirm() }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 460)
        }
    }
    private var connection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TR7Mac").font(.title2.weight(.semibold))
                Picker("Connection", selection: $model.connectionKind) { Text("USB").tag("USB"); Text("Bluetooth").tag("Bluetooth") }.pickerStyle(.segmented).frame(width: 195).disabled(model.busy)
                Spacer()
                if model.connectionKind == "USB" { Button("Refresh Devices") { model.discover() }.disabled(model.busy) }
                else { Button(bluetooth.scanning ? "Stop Scan" : "Scan Bluetooth") { if bluetooth.scanning { bluetooth.stop() } else { bluetooth.start() } }.disabled(model.busy) }
                Button("Read Settings") { model.load() }.disabled(!model.selectionMatchesConnection || model.busy)
            }
            HStack {
                Picker("Logger", selection: $model.selectedPath) {
                    Text("Select a logger").tag("")
                    if model.connectionKind == "USB" {
                        ForEach(model.devices) { Text("\($0.name) · \($0.serial ?? $0.path)").tag($0.path) }
                    } else {
                        ForEach(model.bluetoothLoggerChoices, id: \.id) { logger in
                            Text([logger.name, logger.serial, logger.rssi.map { "\($0) dBm" } ?? "registered"]
                                .compactMap { $0 }.joined(separator: " · ")).tag("ble:" + logger.id.uuidString)
                        }
                    }
                }.disabled(model.busy)
                if model.connectionKind == "Bluetooth" {
                    SecureField("Passcode (if set)", text: $model.passcode).frame(width: 155).disabled(model.busy)
                    Button("Register") { model.registerSelectedBluetoothLogger() }.disabled(model.selectedPath.isEmpty || model.busy)
                    Button("Forget") { model.forgetSelectedBluetoothLogger() }.disabled(model.selectedPath.isEmpty || model.busy)
                }
            }
            if model.connectionKind == "Bluetooth" { Text(bluetooth.status).font(.caption).foregroundColor(.secondary) }
        }
    }
    @ViewBuilder private var detail: some View {
        switch page {
        case .monitor: monitor
        case .data: RecordedDataView(model: model)
        case .recording: recording.disabled(!model.canEdit)
        case .upload: upload.disabled(!model.canEdit)
        case .network: network.disabled(!model.canEdit)
        case .clock: clock.disabled(!model.canEdit)
        case .device: device.disabled(!model.canEdit)
        case .warnings: warnings.disabled(!model.canEdit)
        case .calibration: CalibrationView(model: model)
        case .logs: logView
        case .certificates: certificates
        }
    }
    private var monitor: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let current = model.readings {
                HStack(spacing: 30) {
                    measurement(model.names.channel1.isEmpty ? "Temperature" : model.names.channel1, current.channel1, CurrentReadings.unit(current.attribute1), current.minimum1, current.maximum1)
                    measurement(model.names.channel2.isEmpty ? "Humidity" : model.names.channel2, current.channel2, CurrentReadings.unit(current.attribute2), current.minimum2, current.maximum2)
                }
                if let date = model.readingsAt { Text("Measured \(date, style: .time)").font(.caption).foregroundColor(.secondary) }
                if let r = model.full?.recording { Text("\(r.isRecording ? "Recording" : "Stopped / waiting") · every \(r.interval) seconds · \(r.endless ? "Endless" : "One-time")") }
            } else { Text("Read a connected logger to view measurements.").foregroundColor(.secondary) }
            HStack {
                Button("Refresh Readings") { model.refreshCurrent() }.disabled(!model.canEdit)
                Toggle("Monitor every 5 seconds", isOn: $model.monitoring).disabled(!model.canEdit && !model.monitoring)
            }
            Button("Clear Max / Min…") { model.pending = .maxmin }.disabled(!model.canEdit)
        }
    }
    private func measurement(_ title: String, _ value: Double?, _ unit: String, _ minimum: Double?, _ maximum: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundColor(.secondary)
            Text("\(format(value)) \(unit)").font(.system(size: 36, weight: .medium, design: .rounded)).monospacedDigit()
            Text("Min \(format(minimum))  ·  Max \(format(maximum))").font(.caption).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func format(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
    private var recording: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let r = model.full?.recording { Text("Currently \(r.isRecording ? "recording" : "stopped / waiting") at a \(r.interval)-second interval.") }
            Picker("Recording interval", selection: $model.recordingInterval) {
                ForEach([1, 2, 5, 10, 15, 20, 30, 60, 120, 300, 600, 900, 1200, 1800, 3600], id: \.self) { Text($0 < 60 ? "\($0) seconds" : "\($0 / 60) minutes").tag($0) }
            }.frame(maxWidth: 340)
            Picker("When memory is full", selection: $model.endless) { Text("Overwrite oldest readings (endless)").tag(true); Text("Stop recording (one-time)").tag(false) }.frame(maxWidth: 440)
            Toggle("Program a future start", isOn: $model.programmedStart)
            if model.programmedStart { DatePicker("Start at", selection: $model.startDate, in: Date()..., displayedComponents: [.date, .hourAndMinute]) }
            Text("Starting a new recording erases the logger's existing recorded data. Download it first. Capacity: 30,000 paired readings.").font(.callout).foregroundColor(.secondary)
            HStack {
                Button("Stop Recording…") { model.pending = .stop }
                Spacer()
                Button("Start New Recording…") { model.pending = .start }.disabled(model.full?.recording == nil)
            }
        }
    }
    private var upload: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Host / path", text: $model.address)
            HStack {
                TextField("Port", text: $model.port).frame(width: 100)
                Picker("Protocol", selection: $model.destinationMode) { Text("HTTP").tag(UInt16(7)); Text("HTTPS").tag(UInt16(0)); if ![UInt16(0), 7].contains(model.destinationMode) { Text("Current mode \(model.destinationMode)").tag(model.destinationMode) } }.frame(width: 250)
            }
            Text("Enter a server host and optional path without a URL scheme. HTTPS requires the appropriate root certificate on the logger.").font(.caption).foregroundColor(.secondary)
            HStack { Spacer(); Button("Save Destination…") { model.pending = .destination }.disabled(!model.destinationChanged) }
            HStack {
                ForEach(UploadDestinationPreset.allCases, id: \.self) { preset in
                    Button(preset.rawValue) { model.address = preset.address; model.port = "443"; model.destinationMode = 0 }
                }
            }
            Divider()
            Toggle("Enable regular uploads", isOn: $model.regularUpload)
            Picker("Upload every", selection: $model.interval) {
                let values = [60, 120, 300, 600, 900, 1200, 1800, 3600, 7200, 10800, 14400, 21600, 43200, 86400]
                if !values.contains(model.interval) { Text("\(model.interval) seconds (current)").tag(model.interval) }
                ForEach(values, id: \.self) { Text($0 < 3600 ? "\($0 / 60) minutes" : "\($0 / 3600) hours").tag($0) }
            }.disabled(!model.regularUpload).frame(maxWidth: 350)
            if model.settings?.scheduledUploadEnabled == true { Text("Scheduled uploads are enabled. Saving the regular interval preserves their times.").font(.caption).foregroundColor(.secondary) }
            HStack { Button("Use 10 Minutes") { model.regularUpload = true; model.interval = 600 }; Spacer(); Button("Save Interval…") { model.pending = .interval }.disabled(!model.intervalChanged) }
            Button("Turn OFF All Uploads…") { model.pending = .uploadsOff }.disabled(model.settings?.uploadEnabled != true && model.settings?.scheduledUploadEnabled != true)
            Divider()
            connectionTest
        }
    }
    @ViewBuilder private var network: some View {
        if model.networkDrafts.indices.contains(model.networkIndex) {
            Picker("Wi-Fi profile", selection: $model.networkIndex) { ForEach(model.networkDrafts.indices, id: \.self) { Text("Profile \($0 + 1)").tag($0) } }.pickerStyle(.segmented)
            HStack {
                Button("Scan Nearby Wi-Fi") { model.scanAccessPoints() }
                if !model.accessPoints.isEmpty { Text("\(model.accessPoints.count) found").font(.caption).foregroundColor(.secondary) }
            }
            ForEach(model.accessPoints) { accessPoint in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(accessPoint.ssid.isEmpty ? "Hidden network" : accessPoint.ssid)
                        Text("\(accessPoint.security) · channel \(accessPoint.channel) · \(accessPoint.rssi) dBm")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Use") { model.networkDrafts[model.networkIndex].ssid = accessPoint.ssid }
                        .disabled(accessPoint.ssid.isEmpty)
                }
                Divider()
            }
            if !model.accessPoints.isEmpty {
                Text("Use copies the network name into this profile. Confirm its password and security settings before saving.").font(.caption).foregroundColor(.secondary)
            }
            NetworkEditor(profile: $model.networkDrafts[model.networkIndex])
            HStack { Spacer(); Button("Save Network Profile…") { model.pending = .network } }
            Divider()
            connectionTest
        } else { Text("Read a logger with supported Wi-Fi profiles.").foregroundColor(.secondary) }
    }
    private var clock: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Internal UTC calendar: \(model.settings?.clock.description ?? "—")").monospacedDigit()
            Picker("Calendar shown", selection: $model.clockZone) { Text("UTC").tag("UTC"); Text(TimeZone.current.identifier).tag("Local") }.pickerStyle(.segmented)
            DatePicker("Set calendar to", selection: $model.clockDate, displayedComponents: [.date, .hourAndMinute]).environment(\.timeZone, model.timeZone)
            Text("The displayed calendar fields are sent literally. Use UTC to synchronize the internal clock with the computer.").font(.caption).foregroundColor(.secondary)
            HStack { Button("Use Computer UTC") { model.clockZone = "UTC"; model.clockDate = Date() }; Spacer(); Button("Set Clock…") { model.pending = .clock } }
            Divider()
            Stepper("Timezone: \(model.timezoneMinutes) minutes from UTC", value: $model.timezoneMinutes, in: -720...840, step: 15)
            Toggle("Daylight saving", isOn: $model.daylightSaving)
            Stepper("Daylight offset: \(model.daylightMinutes) minutes", value: $model.daylightMinutes, in: 0...120, step: 15).disabled(!model.daylightSaving)
            Toggle("Synchronize using SNTP", isOn: $model.sntpEnabled)
            TextField("Time server", text: $model.sntpServer).disabled(!model.sntpEnabled)
            HStack { Button("Use Computer Timezone") { model.timezoneMinutes = (TimeZone.current.secondsFromGMT() - Int(TimeZone.current.daylightSavingTimeOffset())) / 60; model.daylightSaving = TimeZone.current.isDaylightSavingTime(); model.daylightMinutes = 60 }; Spacer(); Button("Save Time Settings…") { model.pending = .time } }
            Divider()
            if model.timers.indices.contains(model.timerIndex) {
                Picker("Daily max/min reset", selection: $model.timerIndex) { Text("Channel 1").tag(0); Text("Channel 2").tag(1) }.pickerStyle(.segmented)
                TimerEditor(timer: $model.timers[model.timerIndex])
                Button("Save Reset Timer…") { model.pending = .timer }
            }
        }
    }
    private var device: some View {
        VStack(alignment: .leading, spacing: 16) {
            identityField("Device name", text: $model.names.device)
            identityField("Group name", text: $model.names.group)
            identityField("Channel 1 name", text: $model.names.channel1)
            identityField("Channel 2 name", text: $model.names.channel2)
            Text("Device name: 26 UTF-8 bytes; other names: 16 bytes each.").font(.caption).foregroundColor(.secondary)
            Button("Save Names…") { model.pending = .names }.disabled(model.full?.names == nil)
            Divider()
            Toggle("Display temperature in Fahrenheit", isOn: $model.fahrenheit)
            Button("Set Temperature Unit…") { model.pending = .unit }
            if model.connectionKind == "USB" { Toggle("Enable Bluetooth", isOn: $model.bluetoothEnabled); Button("Set Bluetooth Availability…") { model.pending = .bluetooth } }
            SecureField("New six-digit Bluetooth passcode", text: $model.newPasscode).frame(maxWidth: 300)
            Button("Change Bluetooth Passcode…") { model.pending = .passcode }
            Text("Passcodes and Wi-Fi passwords stay in memory and are excluded from settings exports.").font(.caption).foregroundColor(.secondary)
            Divider()
            if let firmware = model.full?.responses["firmware"], firmware.count >= 20 {
                Text("Firmware  ·  Logger \(String(data: firmware[8..<12], encoding: .ascii) ?? "—")  ·  Wi-Fi \(String(data: firmware[12..<16], encoding: .ascii) ?? "—")  ·  Bluetooth \(String(data: firmware[16..<20], encoding: .ascii) ?? "—")").font(.caption)
            }
            Button("Factory Reset…") { model.pending = .reset }.foregroundColor(.red)
        }
    }
    private func identityField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(label).frame(width: 110, alignment: .trailing)
            TextField(label, text: text).labelsHidden()
        }
    }
    @ViewBuilder private var warnings: some View {
        if let warnings = model.warnings {
            WarningEditor(value: Binding(get: { model.warnings ?? warnings }, set: { model.warnings = $0 }))
            Text("Only enabled warnings are monitored. A reading must pass an enabled limit for the selected judgment time before a warning occurs. Limits below −60°C or above 70°C, or humidity limits outside 0–100%, are outside the TR72A's measurement range.").font(.caption).foregroundColor(.secondary)
            HStack { Button("Clear ALM…") { model.pending = .alarm }; Spacer(); Button("Save Warning Settings…") { model.pending = .warnings }.disabled(!model.warningsChanged) }
        } else { Text("Warning settings are unavailable. Read a supported logger.").foregroundColor(.secondary) }
    }
    private var logView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Button("Read Operation Log") { model.readLogs() }.disabled(!model.canEdit); Spacer(); Button("Export CSV…") { model.exportLogs() }.disabled(model.logs.isEmpty || model.busy) }
            ForEach(model.logs) { entry in
                HStack(alignment: .top) { Text(entry.date.formatted()).frame(width: 175, alignment: .leading).monospacedDigit(); Text(entry.description); Spacer(); Text(String(format: "%02X/%02X", entry.category, entry.code)).foregroundColor(.secondary) }.font(.caption)
                Divider()
            }
        }
    }
    private var certificates: some View {
        CertificatesView(info: model.certificateInfo, canEdit: model.canEdit, usb: model.connectionKind == "USB",
                         read: model.readCertificates, install: model.installCertificate, delete: model.deleteCertificate)
    }
    private var connectionTest: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Test network", selection: $model.networkIndex) {
                ForEach(model.networkDrafts.indices, id: \.self) { Text("Profile \($0 + 1)").tag($0) }
            }.frame(maxWidth: 300)
            Button("Connection Test…") { model.pending = .connectionTest }.disabled(!model.canEdit || model.networkDrafts.isEmpty)
            Text("Tests the network and destination saved on the logger. Save any edits before testing.").font(.caption).foregroundColor(.secondary)
            ForEach(model.connectionTestEvents) { event in
                Text("\(event.date?.formatted() ?? "—") · \(event.description)").font(.caption).textSelection(.enabled)
            }
        }
    }
}

struct NetworkEditor: View {
    @Binding var profile: NetworkProfile
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Enable this Wi-Fi profile", isOn: $profile.enabled)
            TextField("Network name (SSID)", text: $profile.ssid)
            SecureField("Wi-Fi password", text: $profile.password)
            Text("WPA/WPA2 personal settings are preserved from the logger. Network names use up to 32 ASCII bytes.").font(.caption).foregroundColor(.secondary)
            Toggle("Obtain IP address automatically (DHCP)", isOn: $profile.dhcp)
            VStack(spacing: 10) { TextField("IP address", text: $profile.address); TextField("Subnet mask", text: $profile.mask); TextField("Gateway", text: $profile.gateway); TextField("Primary DNS", text: $profile.dns1); TextField("Secondary DNS", text: $profile.dns2) }.disabled(profile.dhcp)
            Divider()
            TextField("Proxy host (blank disables)", text: $profile.proxy)
            TextField("Proxy port", value: $profile.proxyPort, formatter: NumberFormatter()).frame(maxWidth: 140)
        }
    }
}
struct TimerEditor: View {
    @Binding var timer: MaxMinTimer
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enable daily reset", isOn: $timer.enabled)
            HStack { Stepper("Hour \(timer.hour)", value: $timer.hour, in: 0...23); Stepper("Minute \(timer.minute)", value: $timer.minute, in: 0...59); Stepper("Second \(timer.second)", value: $timer.second, in: 0...59) }.disabled(!timer.enabled)
        }
    }
}
struct WarningEditor: View {
    @Binding var value: WarningSettings
    private let decimal: NumberFormatter = { let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 1; return f }()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Channel 1 · °C").font(.headline)
            HStack {
                Toggle("Lower limit", isOn: $value.lower1Enabled)
                TextField("Lower", value: $value.lower1, formatter: decimal).disabled(!value.lower1Enabled)
                Toggle("Upper limit", isOn: $value.upper1Enabled)
                TextField("Upper", value: $value.upper1, formatter: decimal).disabled(!value.upper1Enabled)
            }
            Toggle("Sensor warning", isOn: $value.sensor1Enabled)
            judgmentTime($value.delay1)
            Text("Channel 2 · %RH").font(.headline)
            HStack {
                Toggle("Lower limit", isOn: $value.lower2Enabled)
                TextField("Lower", value: $value.lower2, formatter: decimal).disabled(!value.lower2Enabled)
                Toggle("Upper limit", isOn: $value.upper2Enabled)
                TextField("Upper", value: $value.upper2, formatter: decimal).disabled(!value.upper2Enabled)
            }
            Toggle("Sensor warning", isOn: $value.sensor2Enabled)
            judgmentTime($value.delay2)
            Divider()
            Toggle("Battery warning", isOn: $value.batteryEnabled)
        }
    }
    private func judgmentTime(_ seconds: Binding<Int>) -> some View {
        Picker("Warning judgment time", selection: seconds) {
            if !WarningSettings.judgmentTimes.contains(seconds.wrappedValue) { Text("\(seconds.wrappedValue) seconds (current)").tag(seconds.wrappedValue) }
            ForEach(WarningSettings.judgmentTimes, id: \.self) { Text($0 < 60 ? "\($0) seconds" : "\($0 / 60) minutes").tag($0) }
        }.frame(maxWidth: 340)
    }
}
