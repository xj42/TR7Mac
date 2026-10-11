import Foundation
import TR7Core

private final class CertificateLogger: LoggerTransport {
    var table = Data(repeating: 0, count: 64)
    var identity = Data("valid from".utf8) + Data(repeating: 0, count: 118)
    var commands: [Packet] = []
    var bytes = Data()
    var ignoredTable = false
    var failTransfer = false
    var closed = false
    func exchange(_ packet: Packet) throws -> Data {
        commands.append(packet)
        switch packet.command {
        case 0xCB: return table
        case 0xCE: return identity
        case 0xCA:
            if failTransfer { throw TR7Error.timeout }
            bytes.append(packet.payload.dropFirst(6)); return Data()
        case 0xCC:
            if !ignoredTable { table = Data(packet.payload.dropFirst(2)); identity = Data("TR7 protocol test root".utf8) + Data(repeating: 0, count: 106) }
            return Data()
        case 0xCD: table = Data(repeating: 0, count: 64); return Data()
        default: throw CheckFailed(message: "Unexpected certificate command")
        }
    }
    func close() { closed = true }
}

extension Checks {
    static func certificateChecks() async throws {
        // Public test certificate only. OpenSSL independently reports 1,319 DER
        // bytes, NotBefore 2026-10-12 09:47:21Z, NotAfter 2027-10-12 09:47:21Z.
        let pem = """
        -----BEGIN CERTIFICATE-----
        MIIFIzCCAwugAwIBAgIUdT8q9YeqvWITnHyDG53GMSZWwegwDQYJKoZIhvcNAQEL
        BQAwITEfMB0GA1UEAwwWVFI3IHByb3RvY29sIHRlc3Qgcm9vdDAeFw0yNjEwMTIw
        OTQ3MjFaFw0yNzEwMTIwOTQ3MjFaMCExHzAdBgNVBAMMFlRSNyBwcm90b2NvbCB0
        ZXN0IHJvb3QwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQDGLUqMgBSP
        J6z5kvud/9I0QLr79lkPA/F3pt0rXiyTsWZeWR/4hus55hMyNZ6GPcIzPwbcVit9
        M9WBv5rJ78BcfeW8WxbufVVJ9pkQ0IbDLL0M3OygAI1NSMF0tRjAJf0+mW2ylb6E
        Mc4chnUr9gm5Z6sCR/TRgiDxYE0Xh240Rf9xdyVudtd5+JiRtLvaUk1tDKotm6dt
        IQMJ3BmxFJjFKiT0heHeN3VtGnMMosh4ibkzFY9FosqKv5EiNmRGdFM5ORVaB7kk
        U0bImnPyzD/JG8LJuPv+2K4gW/91ImPcESNoGHD63/ddeo/14Tur7Prd6eslPAQB
        5VHDPILVOYAbgerl/lxpEGGGGOXn/gwgMcl2JNsE7W+oJaQfVYtERAyTYKltNbjW
        ztj+98Nx/F7VgC4KFwEK9cUXdN4D3JmArdVWaV//zqcdYSa/cQstDW1LYc94rGfS
        QAhhbxzLn05faYAcRXyB3QudGeJLQGjPvdRtY5vwhru4NdCGuVO6Oxa3RrENWIoj
        qc4fEpCVi31n3PJUIrDF+hh7kQF18Sl8YvjzaKYVNStEiW6YWCBR491TP4kBLDa6
        6N8QiJRm2bf0+M+Au0YXQUFSur8/0TlGksGxjAD2yRTKQEaT6QAzJ88t3W5j5lZz
        wa5sHDhuK1vmgUQT5K5/I8tsqrGV0HN2AQIDAQABo1MwUTAdBgNVHQ4EFgQUbMsl
        YoZtQo7p8KoHmsqTMY0I7vAwHwYDVR0jBBgwFoAUbMslYoZtQo7p8KoHmsqTMY0I
        7vAwDwYDVR0TAQH/BAUwAwEB/zANBgkqhkiG9w0BAQsFAAOCAgEAQLKd3dicZ8bi
        tHxcvDmlPAUbAl6LI1UcbaJpv35xhz0CsNixavfnpkIt/Fni+6S02UGrmyUiNySA
        XMV0PhVg/GfRAiiSYQBoNk95QElWRHh/3dSRogKgtQNvbp6dFYoNLIXKpjU7NaJN
        slWNrgYAhWy24+fqiabl4h8+agPeorp+XV74zfHrrgiRDoRbv91B38JT1XDLWn+M
        hHxYHrxRJCvaZrx8HoXSDasWwcdeG410L+M9K9SJ8eNXT41iPSJKK7pUs2iO/76w
        KLWR0tckN/6XMZA+Sqxbv6yCUjKMbHEcBQcRRsUbl98rvMZoE9H3Vzflj9PieMz0
        GnG7a26n/Ya11Ve3vaC50p7ZIsm8Q4Cex3peUn2HzuWEMUhJR27FLsymQDKSCH3C
        1woDQIOJ69uT2VRkuMxpmyJn61oJsuAjT2R1yBR8KcIj10s7ommI458Yl4qh1ajM
        gQVhH6uVSaKj8ZlQr2PsPq3cAcXWTbc788H+nxY31eqxKB0OW/1uau0g2VDuVpih
        mM8c+SnBJ90P9JlSC02HkHwrPt9ZvBt/8heKoqNu+IcN5HrQaN6eOX+BeVIiJaK0
        A2Sh5/x0f9FzfVL5r6Isr5xRnIOrbUFq+LXZTGb6U+nQspw9zK+Ab48WIx988RPW
        X2IbvX8kQp/RLlH3G7z4eLA7N863QbA=
        -----END CERTIFICATE-----
        """
        let certificate = try RootCertificate(data: Data(pem.utf8), filename: "root.crt")
        try check(certificate.der.count == 1319, "Certificate PEM decoded size")
        try check(certificate.validFrom.timeIntervalSince1970 == 1791798441 && certificate.validUntil.timeIntervalSince1970 == 1823334441, "X.509 dates use UTC Unix seconds")
        var expectedTable = Data("root.crt".utf8) + Data(repeating: 0, count: 48)
        expectedTable.append(contentsOf: [169, 172, 204, 106, 41, 224, 173, 108])
        try check(certificate.table == expectedTable, "Vendor certificate filename and validity metadata golden vector")
        let packets = certificate.transferPackets
        try check(packets.count == 2 && packets[0].command == 0xCA && packets[0].parameter == 0 && packets[1].parameter == 2, "Certificate transfer command and final marker")
        try check(packets[0].payload.prefix(6) == Data([7, 0, 0, 0, 0x27, 5]) && packets[0].payload.count == 1030, "First certificate chunk header")
        try check(packets[1].payload.prefix(6) == Data([7, 0, 1, 0, 0x27, 5]) && packets[1].payload.count == 301, "Final certificate chunk header")
        try check(Data(packets[0].payload.dropFirst(6)) + Data(packets[1].payload.dropFirst(6)) == certificate.der, "Certificate chunks retain all DER bytes")
        try check(try RootCertificate(data: certificate.der, filename: "root.der").der == certificate.der, "DER certificate accepted")
        try rejects("Certificate chain accepted") { _ = try RootCertificate(data: Data((pem + "\n" + pem).utf8), filename: "chain.pem") }
        try rejects("Certificate with private key accepted") { _ = try RootCertificate(data: Data((pem + "\n-----BEGIN PRIVATE KEY-----").utf8), filename: "key.pem") }
        try rejects("Trailing DER bytes accepted") { _ = try RootCertificate(data: certificate.der + Data([0]), filename: "bad.der") }
        try rejects("Oversized certificate accepted") { _ = try RootCertificate(data: Data(repeating: 0, count: 2049), filename: "big.der") }
        try rejects("Oversized metadata filename accepted") { _ = try RootCertificate(data: certificate.der, filename: String(repeating: "a", count: 57)) }
        try rejects("Certificate metadata path accepted") { _ = try RootCertificate(data: certificate.der, filename: "../root.crt") }
        try rejects("Truncated certificate table accepted") { _ = try CertificateInfo(table: Data(repeating: 0, count: 63), identity: Data(repeating: 0, count: 128)) }
        let absent = try CertificateInfo(table: Data(repeating: 0xFF, count: 64), identity: Data("CA certificate not found\r\nERROR\r\n".utf8))
        try check(!absent.isInstalled, "Firmware's short missing-certificate response accepted")
        try rejects("Empty installed certificate identity accepted") {
            var table = Data(repeating: 0, count: 64); table[0] = 0x41
            _ = try CertificateInfo(table: table, identity: Data())
        }
        try rejects("Oversized certificate identity accepted") { _ = try CertificateInfo(table: Data(repeating: 0, count: 64), identity: Data(repeating: 0, count: 129)) }
        let fake = CertificateLogger(), client = SensorClient(transportFactory: { fake })
        do { _ = try await client.readCertificate(); throw CheckFailed(message: "Unverified certificate transport accepted") } catch TR7Error.invalid { }
        try check(fake.commands.isEmpty && !fake.closed, "USB format required before transport opens")
        let initial = try await client.readCertificate(usb: true)
        try check(!initial.isInstalled && fake.commands.map(\.command) == [0xCB, 0xCE], "Certificate metadata read commands")
        let installed = try await client.installCertificate(certificate, expected: initial, usb: true)
        try check(installed.table == expectedTable && fake.bytes == certificate.der && fake.closed, "Certificate installation and metadata verification")
        try check(fake.commands.first(where: { $0.command == 0xCC })?.payload == Data([7, 0]) + expectedTable, "Certificate table selector framing")
        let writeCount = fake.commands.filter { [0xCA, 0xCC, 0xCD].contains($0.command) }.count
        do { _ = try await client.deleteCertificate(expected: initial, usb: true); throw CheckFailed(message: "Stale certificate deleted") } catch TR7Error.changed { }
        try check(fake.commands.filter { [0xCA, 0xCC, 0xCD].contains($0.command) }.count == writeCount, "Stale certificate snapshot prevents writes")
        let deleted = try await client.deleteCertificate(expected: installed, usb: true)
        try check(!deleted.isInstalled && fake.commands.contains(Packet(command: 0xCD, payload: Data([7, 0]))), "Custom certificate deletion and verification")
        fake.ignoredTable = true
        do { _ = try await client.installCertificate(certificate, expected: deleted, usb: true); throw CheckFailed(message: "Ignored certificate table write accepted") } catch TR7Error.verification { }
        fake.failTransfer = true
        let tablesBefore = fake.commands.filter { $0.command == 0xCC }.count
        do { _ = try await client.installCertificate(certificate, expected: deleted, usb: true); throw CheckFailed(message: "Certificate transfer failure accepted") } catch TR7Error.timeout { }
        try check(fake.commands.filter { $0.command == 0xCC }.count == tablesBefore && fake.closed, "Failed certificate transfer sends no metadata and closes transport")
    }
}
