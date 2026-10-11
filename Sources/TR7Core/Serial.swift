import Foundation
import Darwin
import IOKit
import IOKit.serial

public struct USBLogger: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let serial: String?
    public init(path: String, name: String, serial: String? = nil) { self.path = path; self.name = name; self.serial = serial }
    public static func discover() -> [USBLogger] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [USBLogger] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            }
            guard let path = property(kIOCalloutDeviceKey) as? String,
                  let vendor = property("idVendor") as? NSNumber,
                  let product = property("idProduct") as? NSNumber,
                  vendor.intValue == 0x0CCF, product.intValue == 0x0800 else { continue }
            devices.append(USBLogger(path: path, name: property("USB Product Name") as? String ?? "T&D TR7 logger",
                                     serial: property("USB Serial Number") as? String))
        }
        return devices.sorted { $0.path < $1.path }
    }
}

public protocol LoggerTransport: AnyObject {
    func exchange(_ packet: Packet) throws -> Data
    func close()
}

/// One instance belongs to one serial worker. SensorClient serializes all access.
public final class SerialTransport: LoggerTransport {
    private var descriptor: Int32 = -1
    private let timeout: TimeInterval
    private var original: termios?
    public init(path: String, timeout: TimeInterval = 5) throws {
        guard path.hasPrefix("/dev/") else { throw TR7Error.invalid("Select a USB serial device under /dev/.") }
        self.timeout = timeout
        descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { throw Self.systemError("Cannot open \(path)") }
        do {
            guard ioctl(descriptor, TIOCEXCL) == 0 else { throw Self.systemError("Cannot claim the USB serial port") }
            var options = termios()
            guard tcgetattr(descriptor, &options) == 0 else { throw Self.systemError("Cannot read serial settings") }
            original = options
            cfmakeraw(&options)
            options.c_cflag = (options.c_cflag & ~tcflag_t(CSIZE | PARENB | CSTOPB | CRTSCTS)) | tcflag_t(CS8 | CLOCAL | CREAD)
            cfsetispeed(&options, speed_t(B38400)); cfsetospeed(&options, speed_t(B38400))
            guard tcsetattr(descriptor, TCSANOW, &options) == 0 else { throw Self.systemError("Cannot set serial speed") }
            tcflush(descriptor, TCIOFLUSH)
        } catch { close(); throw error }
    }
    deinit { close() }
    public func close() {
        guard descriptor >= 0 else { return }
        if var options = original { _ = tcsetattr(descriptor, TCSANOW, &options) }
        _ = ioctl(descriptor, TIOCNXCL)
        Darwin.close(descriptor); descriptor = -1
    }
    public func exchange(_ packet: Packet) throws -> Data {
        guard descriptor >= 0 else { throw TR7Error.transport("The USB connection is closed.") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try writeAll(packet.encoded(), deadline: deadline)
        let header = try readExact(5, deadline: deadline)
        guard header[0] == 1 else { throw TR7Error.invalid("Unexpected USB response header.") }
        let count = Int(header[3]) | Int(header[4]) << 8
        guard count <= 4096 else { throw TR7Error.invalid("USB response exceeds the maximum size.") }
        let response = try Packet.decode(header + readExact(count + 2, deadline: deadline), expectedCommand: packet.command)
        guard response.parameter == 6 else { throw TR7Error.rejected(response.parameter) }
        return response.payload
    }
    private func wait(_ events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw TR7Error.timeout }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(remaining * 1000 + 1, 60_000)))
            if result < 0 { if errno == EINTR { continue }; throw Self.systemError("USB polling failed") }
            guard result != 0 else { throw TR7Error.timeout }
            // POLLIN can accompany HUP when the last bytes are still readable.
            if item.revents & events != 0 { return }
            if item.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { throw TR7Error.transport("The logger disconnected.") }
        }
    }
    private func readExact(_ count: Int, deadline: TimeInterval) throws -> Data {
        var result = Data()
        while result.count < count {
            try wait(Int16(POLLIN), deadline: deadline)
            var bytes = [UInt8](repeating: 0, count: count - result.count)
            let n = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw Self.systemError("USB read failed") }
            guard n > 0 else { throw TR7Error.transport("The logger closed the USB connection.") }
            result.append(contentsOf: bytes.prefix(n))
        }
        return result
    }
    private func writeAll(_ data: Data, deadline: TimeInterval) throws {
        var offset = 0
        while offset < data.count {
            try wait(Int16(POLLOUT), deadline: deadline)
            let n = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw Self.systemError("USB write failed") }
            guard n > 0 else { throw TR7Error.transport("USB write made no progress.") }
            offset += n
        }
    }
    private static func systemError(_ context: String) -> TR7Error { .transport("\(context): \(String(cString: strerror(errno))).") }
}
