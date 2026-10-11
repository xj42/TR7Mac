import Foundation

public struct RegisteredBluetoothLogger: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID, name: String) { self.id = id; self.name = name }
}

/// Remember only explicitly registered peripheral identifiers and display names.
/// Authentication stays in memory in the transport; discovery signal strength is never saved.
public final class BluetoothRegistry {
    private let storage: UserDefaults
    private let key: String
    public init(storage: UserDefaults = .standard, key: String = "TR7Mac.registeredBluetoothLoggers") {
        self.storage = storage; self.key = key
    }
    public func list() -> [RegisteredBluetoothLogger] {
        let entries = storage.array(forKey: key) ?? []
        var seen = Set<UUID>()
        return entries.compactMap { entry -> RegisteredBluetoothLogger? in
            guard let fields = entry as? [String: Any], let text = fields["id"] as? String,
                  let id = UUID(uuidString: text), let name = fields["name"] as? String,
                  seen.insert(id).inserted else { return nil }
            return RegisteredBluetoothLogger(id: id, name: Self.displayName(name))
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
    public func register(id: UUID, name: String) {
        var entries = list()
        let logger = RegisteredBluetoothLogger(id: id, name: Self.displayName(name))
        if let index = entries.firstIndex(where: { $0.id == id }) { entries[index] = logger }
        else { entries.append(logger) }
        save(entries)
    }
    public func remove(id: UUID) { save(list().filter { $0.id != id }) }
    private func save(_ entries: [RegisteredBluetoothLogger]) {
        storage.set(entries.map { ["id": $0.id.uuidString, "name": $0.name] }, forKey: key)
    }
    private static func displayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "TR7 Bluetooth logger" : trimmed
    }
}
