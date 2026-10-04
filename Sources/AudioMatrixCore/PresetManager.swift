import Foundation

public enum PresetManager {
    public static var presetsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("OpenAudioMatrix/presets", isDirectory: true)
    }

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
    }

    public static func presetURL(name: String) throws -> URL {
        let sanitized = sanitizeName(name)
        guard !sanitized.isEmpty else {
            throw PresetError.invalidName(name)
        }
        return presetsDirectory.appendingPathComponent("\(sanitized).json")
    }

    public static func listPresets() throws -> [String] {
        try ensureDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: presetsDirectory,
            includingPropertiesForKeys: nil
        )
        return urls
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    public static func save(showPreset: ShowPreset, name: String) throws {
        try ensureDirectory()
        let url = try presetURL(name: name)
        let data = try JSONEncoder().encode(showPreset)
        try data.write(to: url, options: .atomic)
    }

    /// Saves session-only (CLI compatibility); matrix metadata is empty.
    public static func save(session: RoutingSession, name: String) throws {
        try save(showPreset: ShowPreset(session: session), name: name)
    }

    public static func loadShowPreset(name: String) throws -> ShowPreset {
        let url = try presetURL(name: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PresetError.notFound(name)
        }
        let data = try Data(contentsOf: url)
        if let preset = try? JSONDecoder().decode(ShowPreset.self, from: data) {
            return preset
        }
        let session = try JSONDecoder().decode(RoutingSession.self, from: data)
        return ShowPreset(session: session, matrix: .empty)
    }

    public static func load(name: String) throws -> RoutingSession {
        try loadShowPreset(name: name).session
    }

    public static func delete(name: String) throws {
        let url = try presetURL(name: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PresetError.notFound(name)
        }
        try FileManager.default.removeItem(at: url)
    }

    private static func sanitizeName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        return String(trimmed.unicodeScalars.filter { allowed.contains($0) })
            .replacingOccurrences(of: " ", with: "-")
    }
}

/// Plan alias — presets live in `~/Library/Application Support/OpenAudioMatrix/presets/`.
public typealias PresetStore = PresetManager

public enum PresetError: Error, CustomStringConvertible {
    case invalidName(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .invalidName(let name):
            "Invalid preset name: '\(name)'"
        case .notFound(let name):
            "Preset not found: '\(name)'"
        }
    }
}
