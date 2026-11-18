import Foundation

enum SonosDeviceCache {
    private static let storageKey = "cachedSonosDevices"

    static func load() -> [SonosDevice] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let devices = try? JSONDecoder().decode([SonosDevice].self, from: data) else {
            return []
        }
        return devices
    }

    static func save(_ devices: [SonosDevice]) {
        let uniqueDevices = Dictionary(
            devices.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        guard let data = try? JSONEncoder().encode(Array(uniqueDevices.values)) else {
            return
        }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
