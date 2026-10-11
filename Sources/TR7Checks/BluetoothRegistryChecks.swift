import Foundation
import TR7Core

extension Checks {
    static func bluetoothRegistryChecks() throws {
        let suite = "TR7Checks.bluetoothRegistry.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw CheckFailed(message: "Cannot create isolated Bluetooth registration preferences") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = BluetoothRegistry(storage: defaults, key: "registered")
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        try check(registry.list().isEmpty && defaults.object(forKey: "registered") == nil, "Reading registrations does not implicitly register scanned devices")
        registry.register(id: first, name: "Patio")
        registry.register(id: second, name: "Laundry")
        try check(registry.list().map(\.id) == [second, first], "Explicit registrations are sorted by name")
        let reloaded = BluetoothRegistry(storage: defaults, key: "registered")
        try check(reloaded.list() == registry.list(), "Registrations survive reconstruction from saved preferences")
        registry.register(id: first, name: "  Garage  ")
        try check(reloaded.list().count == 2 && reloaded.list().first?.name == "Garage", "Re-registering updates a name without duplicating the peripheral")
        registry.register(id: second, name: "\n ")
        try check(registry.list().first(where: { $0.id == second })?.name == "TR7 Bluetooth logger", "Unnamed registration has a usable display label")
        guard let stored = defaults.array(forKey: "registered") as? [[String: String]] else { throw CheckFailed(message: "Registrations are not plain identifier/name records") }
        try check(stored.allSatisfy { Set($0.keys) == ["id", "name"] }, "Stored registrations contain no credentials or stale RSSI")
        let encoded = try JSONEncoder().encode(RegisteredBluetoothLogger(id: first, name: "Garage"))
        let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: String]
        try check(fields?["id"] == first.uuidString && fields?["name"] == "Garage" && fields?.count == 2, "Codable registration contains only identifier and name")
        registry.remove(id: first)
        try check(reloaded.list().map(\.id) == [second], "Forgetting one logger preserves the other registration")
        registry.remove(id: first)
        try check(reloaded.list().count == 1, "Forgetting an unknown identifier is harmless")
        registry.remove(id: second)
        try check(reloaded.list().isEmpty, "Forgetting the final logger leaves no registrations")

        defaults.set([["id": "not-a-uuid", "name": "Invalid"], ["id": first.uuidString],
                      ["id": first.uuidString, "name": "Known"], ["id": first.uuidString, "name": "Duplicate"]], forKey: "registered")
        try check(registry.list() == [RegisteredBluetoothLogger(id: first, name: "Known")], "Malformed entries and duplicate identifiers do not prevent valid registrations loading")
        defaults.set("invalid value", forKey: "registered")
        try check(registry.list().isEmpty, "Malformed registry preferences do not crash startup")
        registry.register(id: second, name: "Laundry")
        try check(registry.list() == [RegisteredBluetoothLogger(id: second, name: "Laundry")], "Explicit registration restores malformed preferences")
    }
}
