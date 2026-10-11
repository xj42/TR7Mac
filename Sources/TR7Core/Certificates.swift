import Foundation
import Security
import CryptoKit

/// The custom-server root certificate in selector 7. The vendor USB table is
/// a 56-byte filename followed by NotBefore and NotAfter Unix seconds (LE32).
public struct CertificateInfo: Equatable, Sendable {
    public let table: Data
    public let identity: Data
    private var filenameBytes: Data { Data(table.prefix(56).prefix { $0 != 0 && $0 != 255 }) }
    public var filename: String { String(data: filenameBytes, encoding: .utf8) ?? String(data: filenameBytes, encoding: .windowsCP1252) ?? filenameBytes.hex }
    public var isInstalled: Bool { !filenameBytes.isEmpty }
    public var validFrom: Date? { isInstalled ? Date(timeIntervalSince1970: Double(table.dword(56))) : nil }
    public var validUntil: Date? { isInstalled ? Date(timeIntervalSince1970: Double(table.dword(60))) : nil }
    public var description: String { identity.text(0, identity.count) }
    public init(table: Data, identity: Data) throws {
        guard table.count == 64 else {
            throw TR7Error.invalid("The logger returned an unsupported certificate information block.")
        }
        // CE returns only the populated identity text on firmware 1.20. This is
        // short both for an installed subject and for "certificate not found".
        guard (1...128).contains(identity.count) else {
            throw TR7Error.invalid("The logger returned an unsupported certificate identity block (\(identity.count) bytes).")
        }
        self.table = table; self.identity = identity
    }
}

public struct RootCertificate: Sendable {
    public let der: Data
    public let filename: String
    public let subject: String
    public let validFrom: Date
    public let validUntil: Date
    public var fingerprint: String { SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":") }
    public var table: Data {
        var bytes = Data(repeating: 0, count: 64)
        bytes.replaceSubrange(0..<filename.utf8.count, with: Data(filename.utf8))
        bytes.setDword(UInt32(validFrom.timeIntervalSince1970), at: 56)
        bytes.setDword(UInt32(validUntil.timeIntervalSince1970), at: 60)
        return bytes
    }
    public init(data: Data, filename: String) throws {
        guard data.count <= 8192 else { throw TR7Error.invalid("The logger accepts one root certificate of up to 2,048 DER bytes.") }
        guard !filename.isEmpty, filename.utf8.count <= 56,
              !filename.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !filename.contains("/"), !filename.contains("\\") else {
            throw TR7Error.invalid("Use a certificate filename of up to 56 UTF-8 bytes without path separators or control characters.")
        }
        let bytes: Data
        if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN") {
            let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
            guard let start = text.range(of: begin), let finish = text.range(of: end), start.upperBound <= finish.lowerBound,
                  text[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text[finish.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TR7Error.invalid("Select a PEM file containing exactly one certificate and no private key.")
            }
            let base64 = text[start.upperBound..<finish.lowerBound].filter { !$0.isWhitespace }
            guard let decoded = Data(base64Encoded: base64) else { throw TR7Error.invalid("The certificate PEM data is invalid.") }
            bytes = decoded
        } else { bytes = data }
        guard !bytes.isEmpty, bytes.count <= 2048 else { throw TR7Error.invalid("The logger accepts one root certificate of up to 2,048 DER bytes.") }
        guard let certificate = SecCertificateCreateWithData(nil, bytes as CFData) else {
            throw TR7Error.invalid("Select a valid X.509 certificate in DER or PEM format.")
        }
        var cursor = 0
        let outer = try CertificateDER.read(bytes, cursor: &cursor)
        guard outer.tag == 0x30, cursor == bytes.count else { throw TR7Error.invalid("The certificate contains invalid or trailing DER data.") }
        let certificateFields = try outer.children()
        guard certificateFields.count == 3, certificateFields[0].tag == 0x30 else { throw TR7Error.invalid("Invalid X.509 certificate structure.") }
        let fields = try certificateFields[0].children()
        let first = fields.first?.tag == 0xA0 ? 1 : 0
        guard fields.count >= first + 6, fields[first + 3].tag == 0x30 else { throw TR7Error.invalid("The certificate has no supported validity period.") }
        let validity = try fields[first + 3].children()
        guard validity.count == 2 else { throw TR7Error.invalid("Invalid certificate validity period.") }
        let from = try validity[0].date(), until = try validity[1].date()
        guard from.timeIntervalSince1970 >= 0, until.timeIntervalSince1970 <= Double(UInt32.max), from < until else {
            throw TR7Error.invalid("The certificate validity dates cannot be represented by this logger.")
        }
        self.der = bytes; self.filename = filename; validFrom = from; validUntil = until
        subject = SecCertificateCopySubjectSummary(certificate) as String? ?? filename
    }
    /// Matches TdTR7wfCom's 1,024-byte USB transfers, without automatic retries.
    public var transferPackets: [Packet] {
        stride(from: 0, to: der.count, by: 1024).map { offset in
            let count = min(1024, der.count - offset)
            var payload = Data(repeating: 0, count: 6)
            payload.setWord(7, at: 0)
            payload.setWord(UInt16(offset / 1024), at: 2)
            payload.setWord(UInt16(der.count), at: 4)
            payload.append(der.subdata(in: offset..<offset + count))
            return Packet(command: 0xCA, parameter: offset + count == der.count ? 2 : (offset == 0 ? 0 : 1), payload: payload)
        }
    }
}

/// A bounded DER reader for the two standard X.509 validity time encodings.
/// Security.framework validates the certificate before these fields are read.
private struct CertificateDER {
    let tag: UInt8
    let content: Data
    static func read(_ data: Data, cursor: inout Int) throws -> CertificateDER {
        func invalid() -> TR7Error { .invalid("The certificate contains invalid DER data.") }
        guard cursor + 2 <= data.count else { throw invalid() }
        let tag = data[cursor], initial = data[cursor + 1]; cursor += 2
        var length = Int(initial)
        if initial & 0x80 != 0 {
            let count = Int(initial & 0x7F)
            guard (1...2).contains(count), cursor + count <= data.count, data[cursor] != 0 else { throw invalid() }
            length = 0
            for _ in 0..<count { length = length * 256 + Int(data[cursor]); cursor += 1 }
            guard length >= 128 else { throw invalid() }
        }
        guard length <= data.count - cursor else { throw invalid() }
        let content = data.subdata(in: cursor..<cursor + length); cursor += length
        return CertificateDER(tag: tag, content: content)
    }
    func children() throws -> [CertificateDER] {
        var result: [CertificateDER] = [], cursor = 0
        while cursor < content.count { result.append(try Self.read(content, cursor: &cursor)) }
        return result
    }
    func date() throws -> Date {
        guard let text = String(data: content, encoding: .ascii), (tag == 0x17 && text.count == 13) || (tag == 0x18 && text.count == 15), text.last == "Z", text.dropLast().allSatisfy(\.isNumber) else {
            throw TR7Error.invalid("Unsupported certificate validity time.")
        }
        let digits = Array(text.dropLast())
        let yearCount = tag == 0x17 ? 2 : 4
        func number(_ start: Int, _ count: Int = 2) -> Int { Int(String(digits[start..<start + count]))! }
        var year = number(0, yearCount)
        if tag == 0x17 { year += year >= 50 ? 1900 : 2000 }
        let values = [number(yearCount), number(yearCount + 2), number(yearCount + 4), number(yearCount + 6), number(yearCount + 8)]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: values[0], day: values[1], hour: values[2], minute: values[3], second: values[4])
        guard let date = calendar.date(from: components) else {
            throw TR7Error.invalid("Invalid certificate validity date.")
        }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard actual.year == year, [actual.month, actual.day, actual.hour, actual.minute, actual.second] == values.map(Optional.some) else {
            throw TR7Error.invalid("Invalid certificate validity date.")
        }
        return date
    }
}

extension SensorClient {
    public func readCertificate(usb: Bool = false) throws -> CertificateInfo {
        try requireCertificateUSB(usb)
        let transport = try factory(); defer { transport.close() }
        return try certificateInfo(transport)
    }
    public func installCertificate(_ certificate: RootCertificate, expected: CertificateInfo, usb: Bool = false) throws -> CertificateInfo {
        try requireCertificateUSB(usb)
        let transport = try factory(); defer { transport.close() }
        guard try certificateInfo(transport) == expected else { throw TR7Error.changed }
        for packet in certificate.transferPackets {
            try Task.checkCancellation()
            _ = try transport.exchange(packet)
        }
        _ = try transport.exchange(Packet(command: 0xCC, payload: Data([7, 0]) + certificate.table))
        let actual = try certificateInfo(transport)
        guard actual.table == certificate.table else { throw TR7Error.verification("the certificate filename and validity dates did not match") }
        return actual
    }
    public func deleteCertificate(expected: CertificateInfo, usb: Bool = false) throws -> CertificateInfo {
        try requireCertificateUSB(usb)
        let transport = try factory(); defer { transport.close() }
        guard try certificateInfo(transport) == expected else { throw TR7Error.changed }
        _ = try transport.exchange(Packet(command: 0xCD, payload: Data([7, 0])))
        let actual = try certificateInfo(transport)
        guard !actual.isInstalled else { throw TR7Error.verification("the custom root certificate is still present") }
        return actual
    }
    private func certificateInfo(_ transport: LoggerTransport) throws -> CertificateInfo {
        try CertificateInfo(table: transport.exchange(Packet(command: 0xCB, payload: Data([7, 0]))),
                            identity: transport.exchange(Packet(command: 0xCE, payload: Data([7, 0]))))
    }
    private func requireCertificateUSB(_ usb: Bool) throws {
        guard usb else { throw TR7Error.invalid("Certificate management currently requires a USB connection.") }
    }
}
