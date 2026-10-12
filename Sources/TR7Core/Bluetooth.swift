import Foundation
import CoreBluetooth
import Combine

public struct BluetoothLogger: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let serial: String?
    public let rssi: Int
}

/// UUIDs and SCMD framing recovered from TdTR7BleCom.dll 4.30, BleDevice2.
public enum BluetoothProtocol {
    public static let service = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA42")
    public static let command = CBUUID(string: "6E400008-B5A3-F393-E0A9-E50E24DCCA42")
    /// T&D Bluetooth SIG company identifier (0x0392), followed by a little-endian serial.
    public static func isTandDAdvertisement(_ manufacturerData: Data?) -> Bool {
        guard let manufacturerData, manufacturerData.count >= 2 else { return false }
        return manufacturerData[0] == 0x92 && manufacturerData[1] == 0x03
    }
    public static func advertisedSerial(_ manufacturerData: Data?) -> String? {
        guard isTandDAdvertisement(manufacturerData), let manufacturerData, manufacturerData.count >= 6 else { return nil }
        let serial = UInt32(manufacturerData[2]) | UInt32(manufacturerData[3]) << 8 |
            UInt32(manufacturerData[4]) << 16 | UInt32(manufacturerData[5]) << 24
        return String(format: "%08X", serial)
    }
    public static func wirePacket(_ packet: Packet) throws -> Packet {
        guard [UInt8(0x2D), 0x2E, 0x32, 0x33, 0x35, 0x36, 0x37, 0x38, 0x39,
               0x3D, 0x40, 0x41, 0x50, 0x52, 0x53, 0x55, 0x56, 0x6B, 0x6C,
               0x60, 0x61, 0x6D, 0x6F, 0x75, 0x76, 0x78, 0x79, 0x7A, 0x7B,
               0x7C, 0x9F, 0xC4, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE].contains(packet.command) else {
            throw TR7Error.invalid("This Bluetooth command has not been implemented.")
        }
        // The BLE SDK's base command serializer emits four zero bytes for empty requests.
        return Packet(command: packet.command, parameter: packet.parameter,
                      payload: packet.payload.isEmpty ? Data(repeating: 0, count: 4) : packet.payload)
    }
    public static func unlock(passcode: String) throws -> Packet {
        let code: UInt32
        if passcode.isEmpty { code = 0 }
        else {
            guard passcode.utf8.count == 6, passcode.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = UInt32(passcode) else { throw TR7Error.invalid("Enter the logger's six-digit Bluetooth passcode, or leave it blank if no lock is set.") }
            code = number
        }
        var payload = Data(repeating: 0, count: 4); payload.setDword(code, at: 0)
        return Packet(command: 0x76, payload: payload)
    }
}

/// Discovery is explicitly started by the user, so permission is requested in the app bundle.
public final class BluetoothDiscovery: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published public private(set) var devices: [BluetoothLogger] = []
    @Published public private(set) var status = "Click Scan Bluetooth to find nearby loggers."
    @Published public private(set) var scanning = false
    private var central: CBCentralManager?
    private var requested = false
    public func start() {
        precondition(Thread.isMainThread)
        requested = true; devices = []; status = "Starting Bluetooth…"
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { beginIfReady() }
    }
    public func stop() {
        precondition(Thread.isMainThread)
        requested = false; central?.stopScan(); scanning = false
        status = devices.isEmpty ? "Scan stopped. No logger was found." : "Scan stopped. Select a logger, then read its settings."
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) { beginIfReady() }
    private func beginIfReady() {
        guard let central else { return }
        guard central.state == .poweredOn else {
            scanning = false
            switch central.state {
            case .poweredOff: status = "Turn on Bluetooth on this Mac."
            case .unauthorized: status = "Allow TR7Mac in System Settings → Privacy & Security → Bluetooth."
            case .unsupported: status = "Bluetooth Low Energy is unavailable on this Mac."
            default: status = "Waiting for Bluetooth…"
            }
            return
        }
        guard requested else { return }
        scanning = true; status = "Looking for nearby TR7 loggers… Press Stop Scan when finished."
        // Some firmware advertises only its configured name and T&D manufacturer data.
        // Later scan responses can supply the configured name after an unnamed first packet.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = name.uppercased().replacingOccurrences(of: "-", with: "")
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let index = devices.firstIndex(where: { $0.id == peripheral.identifier })
        guard index != nil || normalized.hasPrefix("TR7") || services.contains(BluetoothProtocol.service) ||
            BluetoothProtocol.isTandDAdvertisement(manufacturerData) else { return }
        let previous = index.map { devices[$0] }
        let logger = BluetoothLogger(id: peripheral.identifier,
                                     name: name.isEmpty ? (previous?.name ?? "T&D Bluetooth logger") : name,
                                     serial: BluetoothProtocol.advertisedSerial(manufacturerData) ?? previous?.serial,
                                     rssi: RSSI.intValue)
        if let index {
            guard previous?.name != logger.name || previous?.serial != logger.serial ||
                abs((previous?.rssi ?? logger.rssi) - logger.rssi) >= 10 else { return }
            devices[index] = logger
        } else {
            devices.append(logger); devices.sort { $0.name < $1.name }
        }
        status = "Found \(devices.count) logger\(devices.count == 1 ? "" : "s"); scanning for more…"
    }
}

private final class BluetoothResult<T> {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<T, Error>?
    func finish(_ value: Result<T, Error>) {
        lock.lock(); guard result == nil else { lock.unlock(); return }
        result = value; lock.unlock(); semaphore.signal()
    }
    func wait(seconds: TimeInterval) throws -> T {
        guard semaphore.wait(timeout: .now() + seconds) == .success else { throw TR7Error.timeout }
        lock.lock(); let value = result!; lock.unlock(); return try value.get()
    }
}

/// Blocking transport used only by SensorClient's actor, with delegates on a separate queue.
/// One connection per operation; passcodes remain in memory and are never logged or persisted.
public final class BluetoothTransport: NSObject, LoggerTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    private let queue = DispatchQueue(label: "TR7Mac.bluetooth.transport")
    private let identifier: UUID
    private let ready = BluetoothResult<Void>()
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var characteristic: CBCharacteristic?
    private var closed = false
    private var connecting = false
    private var startupWrite = false
    private var pending: BluetoothResult<Data>?
    private var expectedCommand: UInt8 = 0
    private var outbound = Data()
    private var offset = 0
    private var writeInFlight = false
    private var received = Data()
    private var reply: Result<Data, Error>?
    public init(identifier: UUID, passcode: String, timeout: TimeInterval = 20) throws {
        guard !Thread.isMainThread else { throw TR7Error.invalid("Bluetooth operations must run on a background worker.") }
        let unlock = try BluetoothProtocol.unlock(passcode: passcode)
        self.identifier = identifier
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
        do {
            try ready.wait(seconds: timeout)
            do { _ = try exchange(unlock) }
            catch TR7Error.rejected(let status) {
                throw TR7Error.transport(String(format: "Bluetooth access was rejected (0x%02X). Check the logger's passcode.", status))
            }
        } catch { close(); throw error }
    }
    public func close() {
        queue.sync {
            guard !closed else { return }; closed = true
            ready.finish(.failure(TR7Error.transport("Bluetooth connection closed.")))
            pending?.finish(.failure(TR7Error.transport("Bluetooth connection closed."))); pending = nil
            if let peripheral { peripheral.delegate = nil; central.cancelPeripheralConnection(peripheral) }
            central.delegate = nil
        }
    }
    public func exchange(_ packet: Packet) throws -> Data {
        guard !Thread.isMainThread else { throw TR7Error.invalid("Bluetooth operations must run on a background worker.") }
        let wire = try BluetoothProtocol.wirePacket(packet).encoded()
        let result = BluetoothResult<Data>()
        queue.sync {
            guard !closed, characteristic != nil else { result.finish(.failure(TR7Error.transport("Bluetooth connection is closed."))); return }
            guard pending == nil else { result.finish(.failure(TR7Error.transport("A Bluetooth command is already in progress."))); return }
            pending = result; expectedCommand = packet.command; outbound = wire; offset = 0
            received = Data(); reply = nil; writeInFlight = false; sendNext()
        }
        do { return try result.wait(seconds: 10) }
        catch TR7Error.rejected(let status) { throw TR7Error.rejected(status) }
        catch { close(); throw error } // Never reuse a connection with a late or malformed response.
    }
    private func sendNext() {
        guard let peripheral, let characteristic, pending != nil else { return }
        guard offset < outbound.count else { finishIfReady(); return }
        let end = min(offset + min(20, peripheral.maximumWriteValueLength(for: .withResponse)), outbound.count)
        guard end > offset else { fail(TR7Error.transport("Bluetooth negotiated an invalid write size.")); return }
        let chunk = outbound.subdata(in: offset..<end); offset = end; writeInFlight = true
        peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
    }
    private func finishIfReady() {
        guard !writeInFlight, offset == outbound.count, let reply else { return }
        let result = pending; pending = nil; result?.finish(reply)
    }
    private func fail(_ error: Error) {
        ready.finish(.failure(error)); pending?.finish(.failure(error)); pending = nil
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !closed else { return }
        if central.state == .poweredOn {
            guard !connecting else { return }; connecting = true
            guard let device = central.retrievePeripherals(withIdentifiers: [identifier]).first else {
                fail(TR7Error.transport("The Bluetooth logger is no longer available. Scan again.")); return
            }
            peripheral = device; device.delegate = self; central.connect(device)
        } else if central.state != .unknown && central.state != .resetting {
            fail(TR7Error.transport(central.state == .unauthorized ? "Bluetooth permission was denied. Allow TR7Mac in System Settings." : "Bluetooth is unavailable or turned off."))
        }
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { peripheral.discoverServices([BluetoothProtocol.service]) }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(error ?? TR7Error.transport("Could not connect to the Bluetooth logger."))
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        fail(error ?? TR7Error.transport("The Bluetooth logger disconnected."))
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { fail(error); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == BluetoothProtocol.service }) else {
            fail(TR7Error.transport("This device does not expose the TR7 Bluetooth service.")); return
        }
        peripheral.discoverCharacteristics([BluetoothProtocol.command], for: service)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { fail(error); return }
        guard let command = service.characteristics?.first(where: { $0.uuid == BluetoothProtocol.command }),
              command.properties.contains(.write), command.properties.contains(.notify) else {
            fail(TR7Error.transport("This logger uses an older Bluetooth interface. Its handshake is not supported yet; use USB for this firmware.")); return
        }
        characteristic = command; peripheral.setNotifyValue(true, for: command)
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error { fail(error) }
        else if characteristic.isNotifying {
            // BleDevice2::doBreak (0x1001D610) writes a single zero byte before unlock.
            startupWrite = true; peripheral.writeValue(Data([0]), for: characteristic, type: .withResponse)
        }
        else { fail(TR7Error.transport("Bluetooth notifications could not be enabled.")) }
    }
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if startupWrite {
            startupWrite = false
            if let error { fail(error) }
            else { queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in self?.ready.finish(.success(())) } }
            return
        }
        guard pending != nil else { return }
        if let error { fail(error); return }
        writeInFlight = false; sendNext()
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard pending != nil else { return }
        if let error { fail(error); return }
        guard let data = characteristic.value else { return }; received.append(data)
        do {
            guard received.count <= 4103 else { throw TR7Error.invalid("Bluetooth response is too large.") }
            guard received.count >= 5 else { return }
            guard received[0] == 1 else { throw TR7Error.invalid("Unsupported Bluetooth response framing.") }
            let length = Int(received[3]) | Int(received[4]) << 8
            guard length <= 4096, received.count <= length + 7 else { throw TR7Error.invalid("Invalid Bluetooth response length.") }
            guard received.count == length + 7 else { return }
            let packet = try Packet.decode(received, expectedCommand: expectedCommand)
            reply = packet.parameter == 6 ? .success(packet.payload) : .failure(TR7Error.rejected(packet.parameter))
            finishIfReady()
        } catch { fail(error) }
    }
}
