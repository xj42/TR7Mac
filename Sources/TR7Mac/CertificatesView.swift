import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TR7Core

struct CertificatesView: View {
    let info: CertificateInfo?
    let canEdit: Bool
    let usb: Bool
    let read: () -> Void
    let install: (RootCertificate) -> Void
    let delete: () -> Void
    @State private var candidate: RootCertificate?
    @State private var error: String?
    @State private var confirmingInstall = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom Server Root Certificate").font(.headline)
            Text("Choose the root certificate supplied by your HTTPS server operator. The logger stores one custom-server root certificate, up to 2,048 DER bytes.").foregroundColor(.secondary)
            if !usb { Text("Connect by USB to read, install or delete a root certificate.").foregroundColor(.secondary) }
            Button("Read Certificate") { read() }.disabled(!canEdit || !usb)
            if let info {
                if info.isInstalled {
                    Text(info.filename).font(.headline)
                    if let from = info.validFrom, let until = info.validUntil {
                        Text("Valid \(from.formatted(date: .abbreviated, time: .omitted)) – \(until.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                    }
                    if !info.description.isEmpty { Text(info.description).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    Button("Delete Certificate…") { confirmingDelete = true }.disabled(!canEdit || !usb)
                } else { Text("No custom root certificate is installed.").foregroundColor(.secondary) }
            }
            Divider()
            Button("Choose Certificate…") { choose() }.disabled(!canEdit || !usb)
            if let error { Text(error).foregroundColor(.red).font(.caption) }
            if let candidate {
                Text(candidate.filename).font(.headline)
                Text(candidate.subject)
                Text("\(candidate.der.count) DER bytes · valid \(candidate.validFrom.formatted(date: .abbreviated, time: .omitted)) – \(candidate.validUntil.formatted(date: .abbreviated, time: .omitted))").font(.caption)
                if candidate.validUntil < Date() { Text("This certificate has expired.").foregroundColor(.orange).font(.caption) }
                else if candidate.validFrom > Date() { Text("This certificate is not yet valid.").foregroundColor(.orange).font(.caption) }
                Text("SHA-256: \(candidate.fingerprint)").font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                Button("Install Certificate…") { confirmingInstall = true }.disabled(!canEdit || !usb || info == nil)
                if info == nil { Text("Read the current certificate before installing.").foregroundColor(.secondary).font(.caption) }
            }
        }
        .alert("Install Root Certificate?", isPresented: $confirmingInstall) {
            Button("Cancel", role: .cancel) {}
            Button("Install") { if let candidate { install(candidate) } }
        } message: {
            Text("Install \(candidate?.filename ?? "this certificate") for the custom HTTPS server? This replaces the existing custom root certificate. Confirm its SHA-256 fingerprint with your server operator.")
        }
        .alert("Delete Root Certificate?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("Delete \(info?.filename ?? "the custom root certificate")? HTTPS uploads that depend on it may fail.")
        }
        .onChange(of: canEdit) { value in if !value { confirmingInstall = false; confirmingDelete = false } }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Root Certificate"
panel.allowedContentTypes = [
    UTType(filenameExtension: "cer")!,
    UTType(filenameExtension: "crt")!,
    UTType(filenameExtension: "der")!,
    UTType(filenameExtension: "pem")!
]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        error = nil; candidate = nil
        Task {
            do {
                let certificate = try await Task.detached {
                    let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                    return try RootCertificate(data: bytes, filename: url.lastPathComponent)
                }.value
                candidate = certificate
            } catch { self.error = error.localizedDescription }
        }
    }
}
