import Testing
@testable import KambuchaCore

struct PresetCatalogTests {
    @Test func containsAllSpecPresets() throws {
        let ids = Set(try PresetCatalog.all().map(\.id))
        #expect(ids == ["node", "web", "expo", "flutter", "ios", "android", "php", "python", "ruby", "rust-go-java-dotnet"])
    }

    @Test func ambiguousNamesAreNeverAlwaysExcluded() throws {
        let ambiguous: Set<String> = ["build", "dist", "out", "bin", "obj", "target", "vendor", "coverage"]
        for p in try PresetCatalog.all() {
            for pattern in p.alwaysExclude {
                let name = pattern.hasSuffix("/") ? String(pattern.dropLast()) : pattern
                #expect(!ambiguous.contains(name), "\(p.id) always-excludes \(pattern)")
            }
            #expect(!p.markers.isEmpty, "\(p.id) has no markers")
        }
        // and they do appear as ambiguous where the spec lists them
        let all = try PresetCatalog.all()
        #expect(all.first { $0.id == "php" }?.ambiguousExclude == ["vendor/"])
        #expect(all.first { $0.id == "rust-go-java-dotnet" }?.ambiguousExclude == ["target/", "bin/", "obj/"])
    }

    @Test func secretPatternsMatchSpec() {
        #expect(PresetCatalog.secretPatterns == [
            ".env*", "*.pem", "*.key", "*.p8", "*.p12", "*.pfx", "*.jks", "*.keystore",
            "*.mobileprovision", "*.cer", "*.crt", "id_rsa*", "id_ed25519*",
            "google-services.json", "GoogleService-Info.plist", "key.properties",
            ".npmrc", "auth.json", "*service-account*.json",
        ])
        #expect(PresetCatalog.macOSExcludes == [".DS_Store", ".Trash/"])
    }
}
