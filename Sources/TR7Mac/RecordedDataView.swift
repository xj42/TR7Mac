import SwiftUI
import TR7Core
import UniformTypeIdentifiers

struct RecordedDataView: View {
    @ObservedObject var model: LoggerModel
    @State private var show1 = true
    @State private var show2 = true
    @State private var first = 1
    @State private var last = 30000
    @State private var cursor = 1
    @State private var tableOffset = 0
    @State private var filterDates = false
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var downloadRange = "Readings"
    @State private var period = 24
    @State private var periodUnit = 3600
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("Range", selection: $downloadRange) { Text("Readings").tag("Readings"); Text("Recent period").tag("Period") }.frame(maxWidth: 190)
                if downloadRange == "Period" {
                    Stepper("\(period)", value: $period, in: 1...1250).frame(maxWidth: 100)
                    Picker("Unit", selection: $periodUnit) { Text("Hours").tag(3600); Text("Days").tag(86400) }.labelsHidden().frame(maxWidth: 100)
                } else {
                    Picker("Download", selection: $model.downloadCount) { Text("All readings").tag(0); Text("Last 100").tag(100); Text("Last 1,000").tag(1000); Text("Last 10,000").tag(10000) }.labelsHidden().frame(maxWidth: 180)
                }
                Button("Download") { model.download(periodSeconds: downloadRange == "Period" ? period * periodUnit : nil) }.disabled(!model.canEdit)
                Spacer()
                Button("Open Archive…") { model.importData() }.disabled(model.busy)
            }
            if downloadRange == "Period" { Text("Download the most recent \(period) \(periodUnit == 3600 ? "hours" : "days") of stored recordings, ending at the last recorded reading.").font(.caption).foregroundColor(.secondary) }
            if model.busy && model.downloadProgress > 0 { HStack { ProgressView(value: model.downloadProgress); Button("Cancel") { model.cancel() } } }
            if let data = model.downloaded {
                let rows = data.readings
                let start = min(max(1, first), max(1, rows.count)), end = min(max(start, last), max(1, rows.count))
                let selected = rows.isEmpty ? [] : Array(rows[(start - 1)..<end])
                let visible = filterDates ? (startDate <= endDate ? data.readings(in: startDate...endDate).filter { $0.id >= start && $0.id <= end } : []) : selected
                Text("\(data.count) paired readings  ·  \(data.intervalSeconds)-second interval").font(.headline)
                if let firstDate = rows.first?.date, let lastDate = rows.last?.date { Text("\(firstDate.formatted()) – \(lastDate.formatted())").font(.caption).foregroundColor(.secondary) }
                HStack {
                    Toggle("Channel 1", isOn: $show1); Toggle("Channel 2", isOn: $show2)
                    Spacer()
                    Button("CSV…") { model.save(Data(data.csv(for: visible).utf8), name: "TR7-recordings.csv", type: .commaSeparatedText) }.disabled(visible.isEmpty)
                    Button("Archive All…") { model.exportData(archive: true) }
                    Button("Report…") { model.save(Data(data.htmlReport(for: visible).utf8), name: "TR7-report.html", type: .html) }.disabled(visible.isEmpty)
                }.disabled(model.busy)
                if !rows.isEmpty {
                    HStack { Stepper("First: \(start)", value: $first, in: 1...rows.count); Stepper("Last: \(end)", value: $last, in: 1...rows.count); Button("Show All") { first = 1; last = rows.count; filterDates = false } }
                    Toggle("Filter by date and time", isOn: $filterDates).disabled(data.lastSampleDate == nil)
                    if data.lastSampleDate == nil { Text("Date filtering is unavailable because the recording has no known timestamp.").font(.caption).foregroundColor(.secondary) }
                    if filterDates {
                        DatePicker("From", selection: $startDate, displayedComponents: [.date, .hourAndMinute])
                        DatePicker("Through", selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                        if startDate > endDate { Text("The start must be at or before the end.").font(.caption).foregroundColor(.red) }
                    }
                    Text("Showing \(visible.count) of \(rows.count) readings. CSV and report use this selection; the archive includes all downloaded readings.").font(.caption).foregroundColor(.secondary)
                    if !visible.isEmpty {
                        if show1 { ReadingChart(samples: visible, channel: 1, unit: CurrentReadings.unit(data.metadata[30])) }
                        if show2 { ReadingChart(samples: visible, channel: 2, unit: CurrentReadings.unit(data.metadata[31])) }
                        Slider(value: Binding(get: { Double(min(max(1, cursor), visible.count)) }, set: { cursor = Int($0) }), in: 1...Double(max(2, visible.count)), step: 1).disabled(visible.count == 1)
                        let sample = visible[min(max(1, cursor), visible.count) - 1]
                        Text("Sample \(sample.id) · \(sample.date?.formatted() ?? "Unknown time") · \(value(sample.channel1)) \(CurrentReadings.unit(data.metadata[30])) · \(value(sample.channel2)) \(CurrentReadings.unit(data.metadata[31]))").font(.caption).monospacedDigit().textSelection(.enabled)
                        Divider()
                        HStack { Text("Readings").font(.headline); Spacer(); Button("Previous") { tableOffset = max(0, tableOffset - 100) }.disabled(tableOffset == 0); Button("Next") { tableOffset += 100 }.disabled(tableOffset + 100 >= visible.count) }
                        let offset = min(tableOffset, max(0, visible.count - 1))
                        ForEach(visible.dropFirst(offset).prefix(100)) { row in
                            HStack { Text("\(row.id)").frame(width: 45, alignment: .trailing); Text(row.date?.formatted() ?? "—").frame(maxWidth: .infinity, alignment: .leading); Text(value(row.channel1)).frame(width: 65, alignment: .trailing); Text(value(row.channel2)).frame(width: 65, alignment: .trailing) }.font(.system(.caption, design: .monospaced))
                        }
                    } else {
                        Text("No readings match the selected range.").foregroundColor(.secondary)
                    }
                } else { Text("The logger has no recorded readings.").foregroundColor(.secondary) }
            } else { Text("Download recorded data from a logger or open a TR7Mac recording archive. CSV includes UTC timestamps, measurements and the original raw values.").foregroundColor(.secondary) }
        }
        .onChange(of: model.downloaded?.downloadedAt) { _ in resetRange() }
        .onAppear { resetRange() }
        .onChange(of: first) { _ in resetPosition() }
        .onChange(of: last) { _ in resetPosition() }
        .onChange(of: startDate) { _ in resetPosition() }
        .onChange(of: endDate) { _ in resetPosition() }
        .onChange(of: filterDates) { _ in resetPosition() }
    }
    private func resetPosition() { cursor = 1; tableOffset = 0 }
    private func resetRange() {
        first = 1; last = model.downloaded?.count ?? 30000; filterDates = false
        startDate = model.downloaded?.readings.first?.date ?? Date()
        endDate = model.downloaded?.lastSampleDate ?? startDate
        resetPosition()
    }
    private func value(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }
}

struct ReadingChart: View {
    let samples: [RecordedSample], channel: Int, unit: String
    private var values: [Double] { samples.compactMap { channel == 1 ? $0.channel1 : $0.channel2 } }
    private var color: Color { channel == 1 ? .orange : .cyan }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let minValue = values.min() ?? 0, maxValue = values.max() ?? 1
            HStack { Text("Channel \(channel) · \(unit)").font(.headline); Spacer(); Text(String(format: "Min %.1f · Max %.1f · Mean %.1f", minValue, maxValue, values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count))).font(.caption).foregroundColor(.secondary) }
            HStack(spacing: 8) {
                VStack { Text(String(format: "%.1f", maxValue)); Spacer(); Text(String(format: "%.1f", minValue)) }.font(.system(.caption2, design: .monospaced)).frame(width: 40, alignment: .trailing)
                Canvas { context, size in
                    let padding = max(0.1, (maxValue - minValue) * 0.05), low = minValue - padding, high = maxValue + padding
                    var grid = Path()
                    for index in 0...4 { let y = size.height * CGFloat(index) / 4; grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                    context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                    var path = Path(), connected = false
                    // Retain each pixel column's extremes so brief spikes remain visible at full range.
                    let bucket = max(1, samples.count / max(1, Int(size.width)))
                    for start in stride(from: 0, to: samples.count, by: bucket) {
                        let end = min(start + bucket, samples.count)
                        let points = (start..<end).compactMap { index -> (Int, Double)? in (channel == 1 ? samples[index].channel1 : samples[index].channel2).map { (index, $0) } }
                        if points.count != end - start { connected = false }
                        let extremes = [points.min { $0.1 < $1.1 }, points.max { $0.1 < $1.1 }].compactMap { $0 }.sorted { $0.0 < $1.0 }
                        for (index, value) in extremes {
                            let point = CGPoint(x: size.width * CGFloat(index) / CGFloat(max(1, samples.count - 1)), y: size.height * CGFloat((high - value) / (high - low)))
                            if connected { path.addLine(to: point) } else { path.move(to: point); connected = true }
                        }
                    }
                    context.stroke(path, with: .color(color), lineWidth: 1.5)
                }.frame(height: 150).background(Color.secondary.opacity(0.04)).cornerRadius(5)
            }
        }
    }
}
