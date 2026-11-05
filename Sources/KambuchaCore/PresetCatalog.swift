import Foundation

public enum PresetCatalog {
    /// Stack presets, loaded from the bundled presets.json so new stacks are a data change.
    public static func all() throws -> [Preset] {
        guard let url = Bundle.module.url(forResource: "presets", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([Preset].self, from: Data(contentsOf: url))
    }

    public static let secretPatterns: [String] = [
        ".env*", "*.pem", "*.key", "*.p8", "*.p12", "*.pfx", "*.jks", "*.keystore",
        "*.mobileprovision", "*.cer", "*.crt", "id_rsa*", "id_ed25519*",
        "google-services.json", "GoogleService-Info.plist", "key.properties",
        ".npmrc", "auth.json", "*service-account*.json",
    ]

    public static let macOSExcludes: [String] = [".DS_Store", ".Trash/"]
}
