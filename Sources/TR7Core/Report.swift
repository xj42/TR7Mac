import Foundation

extension DownloadedData {
    public var htmlReport: String { htmlReport(for: readings) }
    public func htmlReport(for rows: [RecordedSample]) -> String {
        let formatter = ISO8601DateFormatter()
        func graph(channel: Int, color: String) -> String {
            let values = rows.compactMap { channel == 1 ? $0.channel1 : $0.channel2 }
            guard let low = values.min(), let high = values.max() else { return "<p>No valid measurements.</p>" }
            let range = max(0.2, high - low)
            var segments = [String](), current = [String]()
            for (index, row) in rows.enumerated() {
                guard let value = channel == 1 ? row.channel1 : row.channel2 else {
                    if !current.isEmpty { segments.append(current.joined(separator: " ")); current = [] }; continue
                }
                current.append(String(format: "%.2f,%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(index) / Double(max(1, rows.count - 1)) * 900, 170 - (value - low) / range * 160))
            }
            if !current.isEmpty { segments.append(current.joined(separator: " ")) }
            let unit = CurrentReadings.unit(metadata.count > 31 ? metadata[29 + channel] : 0)
            return "<h2>Channel \(channel) · \(unit)</h2><p>Minimum \(low) · Maximum \(high) · Mean \(values.reduce(0, +) / Double(values.count))</p><svg viewBox=\"0 0 900 180\" role=\"img\" aria-label=\"Channel \(channel) recording graph\">" + segments.map { "<polyline points=\"\($0)\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"1.5\"/>" }.joined() + "</svg>"
        }
        let start = rows.first?.date.map(formatter.string) ?? "Unknown", end = rows.last?.date.map(formatter.string) ?? "Unknown"
        return """
        <!doctype html><html lang="en"><meta charset="utf-8"><title>TR7 Recording Report</title>
        <style>body{font:15px system-ui;margin:36px auto;max-width:950px;padding:0 20px;color:#182737}svg{width:100%;background:#f3f6f8;border:1px solid #dbe3e9}h2{margin-top:30px}p{color:#526373}@media print{body{margin:10px}}</style>
        <h1>TR7 Recording Report</h1><p>\(rows.count) paired readings of \(count) downloaded · interval \(intervalSeconds) seconds<br>UTC: \(start) to \(end)<br>Downloaded: \(formatter.string(from: downloadedAt))</p>
        \(graph(channel: 1, color: "#c76b13"))\(graph(channel: 2, color: "#1679a3"))
        <p>Missing or unsupported sensor values are omitted. Export CSV for the complete numeric data.</p></html>
        """
    }
}
