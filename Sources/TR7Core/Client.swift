import Foundation

public actor SensorClient {
    public let path: String
    let factory: () throws -> LoggerTransport
    public init(path: String) { self.path = path; factory = { try SerialTransport(path: path) } }
    public init(transportFactory: @escaping () throws -> LoggerTransport) { path = "test"; factory = transportFactory }

    public func read() throws -> LoggerSettings {
        let transport = try factory(); defer { transport.close() }
        return try read(transport)
    }
    func read(_ transport: LoggerTransport) throws -> LoggerSettings {
        let page0 = try transport.exchange(Packet(command: 0x6D, parameter: 0))
        let page1 = try transport.exchange(Packet(command: 0x6D, parameter: 1))
        let clock = try LoggerClock(payload: transport.exchange(Packet(command: 0x6F, parameter: 3)))
        // Read names independently. A missing optional names command must not hide essential settings.
        let names: Data?
        do { names = try transport.exchange(Packet(command: 0x56)) }
        catch TR7Error.rejected { names = nil }
        let name = names.flatMap { String(data: $0.prefix(26).prefix { $0 != 0 }, encoding: .utf8) }
        return try LoggerSettings(page0: page0, page1: page1, clock: clock, name: name?.isEmpty == false ? name! : "T&D logger")
    }
    public func setDestination(address: String, port: Int, mode: UInt16? = nil, expected: LoggerSettings) throws -> LoggerSettings {
        // Validate before the logger enters configuration mode.
        _ = try expected.destinationBlock(address: address, port: port, mode: mode)
        return try configuration { transport in
            let current = try read(transport)
            guard current.page1.prefix(128) == expected.page1.prefix(128) else { throw TR7Error.changed }
            let block = try current.destinationBlock(address: address, port: port, mode: mode)
            try write(block, at: 0x0100, transport: transport)
            let result = try read(transport)
            guard result.page1.prefix(128) == block else { throw TR7Error.verification("the upload destination did not match") }
            return result
        }
    }
    public func setInterval(seconds: Int, enabled: Bool, expected: LoggerSettings) throws -> LoggerSettings {
        _ = try expected.intervalBlock(seconds: seconds, enabled: enabled)
        return try configuration { transport in
            let current = try read(transport)
            guard current.page0[192..<256] == expected.page0[192..<256] else { throw TR7Error.changed }
            let block = try current.intervalBlock(seconds: seconds, enabled: enabled)
            try write(block, at: 0x00C0, transport: transport)
            let result = try read(transport)
            guard result.page0[192..<256] == block else { throw TR7Error.verification("the upload interval did not match") }
            return result
        }
    }
    /// Sends explicitly selected calendar fields. No timezone interpretation is applied on the wire.
    public func setClock(_ clock: LoggerClock) throws -> LoggerSettings {
        let payload = try clock.encoded()
        let transport = try factory(); defer { transport.close() }
        _ = try transport.exchange(Packet(command: 0x6F, parameter: 0, payload: payload))
        let result = try read(transport)
        let difference = result.clock.comparisonDate.timeIntervalSince(clock.comparisonDate)
        guard difference >= 0, difference < 10 else { throw TR7Error.verification("the logger clock did not match") }
        return result
    }
    func write(_ block: Data, at offset: UInt16, transport: LoggerTransport) throws {
        var payload = Data([UInt8(offset & 255), UInt8(offset >> 8)])
        payload.append(block)
        _ = try transport.exchange(Packet(command: 0x6C, parameter: 0x1B, payload: payload))
    }
    func configuration<T>(_ action: (LoggerTransport) throws -> T) throws -> T {
        let transport = try factory(); defer { transport.close() }
        // Match the vendor entry/read/modify/write/exit sequence. Never retry a write blindly.
        do {
            _ = try transport.exchange(Packet(command: 0x50, parameter: 0x1B))
            let result = try action(transport)
            do { _ = try transport.exchange(Packet(command: 0x50)) }
            catch { throw TR7Error.verification("settings were written, but the logger did not confirm leaving configuration mode") }
            return result
        } catch {
            _ = try? transport.exchange(Packet(command: 0x50))
            throw error
        }
    }
}
