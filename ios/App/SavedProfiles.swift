import Foundation

struct SavedProfile: Codable, Identifiable {
    let id: String
    let name: String
    let value: String
    let isLink: Bool
}

enum SavedProfiles {
    static func load() throws -> [SavedProfile] {
        guard let data = try PrivateStore.read("profiles-v1") else { return [] }
        return try JSONDecoder().decode([SavedProfile].self, from: data)
    }
    static func remember(_ value: String, name: String, isLink: Bool) throws -> SavedProfile {
        var all = try load()
        if let existing = all.first(where: { $0.value == value }) { return existing }
        guard all.count < 20 else { throw CatalogError.full }
        let profile = SavedProfile(id: UUID().uuidString, name: String(name.prefix(64)), value: value, isLink: isLink)
        all.append(profile)
        try PrivateStore.write(JSONEncoder().encode(all), "profiles-v1")
        return profile
    }
    static func forget(_ id: String) throws {
        let all = try load().filter { $0.id != id }
        try PrivateStore.write(JSONEncoder().encode(all), "profiles-v1")
    }
    enum CatalogError: LocalizedError {
        case full
        var errorDescription: String? { "Сохранено 20 профилей. Удали ненужный профиль в настройках." }
    }
}
