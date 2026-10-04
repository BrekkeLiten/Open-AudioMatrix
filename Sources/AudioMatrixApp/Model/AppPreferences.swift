import Foundation

struct AppPreferences: Codable, Equatable {
    var autoStartRouting = true
    var showVUMeters = true
    var hasDismissedPermissionsGuide = false

    private static let storageKey = "io.github.brekkeliten.openaudiomatrix.appPreferences"

    static func load() -> AppPreferences {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let prefs = try? JSONDecoder().decode(AppPreferences.self, from: data) else {
            return AppPreferences()
        }
        return prefs
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
