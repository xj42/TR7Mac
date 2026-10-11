import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TR7Core

struct CalibrationView: View {
    @ObservedObject var model: LoggerModel
    @State private var fileBusy = false
    private var current: CalibrationSettings? { model.full?.responses["calibration"].flatMap { try? CalibrationSettings($0) } }
    private var proposed: CalibrationSettings? { current.flatMap { try? model.calibrationDraft.applying(to: $0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let current {
                HStack {
                    ForEach(0..<2) { index in
                        VStack(alignment: .leading) {
                            Text("Channel \(index + 1)").font(.headline)
                            Text(current.channels[index].equation).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let date = current.adjustedAt { Text("Last adjusted \(date.formatted())").font(.caption).foregroundColor(.secondary) }
                Divider()
                CalibrationEditor(value: $model.calibrationDraft, current: current)
                if let proposed {
                    Text("Result: CH1 \(proposed.channels[0].equation); CH2 \(proposed.channels[1].equation)")
                        .font(.caption).monospacedDigit()
                }
                if current.channels.contains(where: { !$0.isIdentity }) {
                    Text("Existing corrections are included in the result. Initialize first to replace an earlier adjustment.")
                        .font(.caption).foregroundColor(.secondary)
                }
                Text("Stop recording before sending adjustments. Starting a new recording erases the logger's stored readings. For temperature/humidity sensors, settings follow the sensor; reconfigure after replacing it.")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Button("Read File…") { readFile() }
                    Button("Save File…") { saveFile() }
                    Spacer()
                    Button("Initialize…") { model.pending = .calibrationReset }
                    Button("Send Settings…") { model.pending = .calibration }
                        .disabled(proposed == nil || model.full?.recording?.isRecording != false)
                }.disabled(!model.canEdit || fileBusy)
                Divider()
                HStack {
                    Text("Settings history").font(.headline)
                    Spacer()
                    Button("Read History") { model.readCalibrationHistory() }.disabled(!model.canEdit)
                }
                if model.calibrationHistory.isEmpty {
                    Text("Read the logger's adjustment history to see previous settings.").font(.caption).foregroundColor(.secondary)
                }
                ForEach(model.calibrationHistory) { entry in
                    HStack(alignment: .top) {
                        Text(entry.date.formatted()).frame(width: 175, alignment: .leading)
                        Text(entry.description)
                    }.font(.caption)
                }
            } else { Text("Sensor adjustment is unavailable. Read a supported logger.").foregroundColor(.secondary) }
        }
    }
    private func readFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileBusy = true
        Task { @MainActor in
            do {
                let draft = try await Task.detached { try CalibrationDraft(windowsFile: Data(contentsOf: url)) }.value
                model.calibrationDraft = draft; model.failed = false; model.message = "Adjustment entries imported. Review the resulting equations before sending."
            } catch { model.failed = true; model.message = error.localizedDescription }
            fileBusy = false
        }
    }
    private func saveFile() {
        do {
            let bytes = try model.calibrationDraft.windowsFile()
            let panel = NSSavePanel(); panel.nameFieldStringValue = "TR7-adjustment.dat"; panel.allowedContentTypes = [.data]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            fileBusy = true
            Task { @MainActor in
                do {
                    try await Task.detached { try bytes.write(to: url, options: .atomic) }.value
                    model.failed = false; model.message = "Saved TR7 for Windows adjustment entries."
                } catch { model.failed = true; model.message = error.localizedDescription }
                fileBusy = false
            }
        } catch { model.failed = true; model.message = error.localizedDescription }
    }
}

struct CalibrationEditor: View {
    @Binding var value: CalibrationDraft
    let current: CalibrationSettings?
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ForEach(0..<2) { index in
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Adjust channel \(index + 1)", isOn: $value.channels[index].enabled)
                    Picker("Method", selection: $value.channels[index].method) {
                        ForEach(CalibrationMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    HStack {
                        Text("Before").frame(maxWidth: .infinity)
                        Text("After").frame(maxWidth: .infinity)
                    }.font(.caption).foregroundColor(.secondary)
                    HStack {
                        TextField("Before 1", value: $value.channels[index].before1, formatter: Self.number)
                        TextField("After 1", value: $value.channels[index].after1, formatter: Self.number)
                    }
                    if value.channels[index].method == .twoPoint {
                        HStack {
                            TextField("Before 2", value: $value.channels[index].before2, formatter: Self.number)
                            TextField("After 2", value: $value.channels[index].after2, formatter: Self.number)
                        }
                    }
                    if value.channels[index].enabled {
                        switch Result(catching: { try value.channels[index].coefficients() }) {
                        case .success(let coefficients): Text(coefficients.equation).font(.caption).monospacedDigit()
                        case .failure(let error): Text(error.localizedDescription).font(.caption).foregroundColor(.red)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.textFieldStyle(.roundedBorder)
        Text("Enter values in °C or %RH, in increments of 0.1. Each point may change by up to ±5. Two-point corrections work best with points well apart.")
            .font(.caption).foregroundColor(.secondary)
    }
    private static let number: NumberFormatter = {
        let result = NumberFormatter(); result.numberStyle = .decimal; result.maximumFractionDigits = 1
        result.minimumFractionDigits = 1; result.usesGroupingSeparator = false
        return result
    }()
}
