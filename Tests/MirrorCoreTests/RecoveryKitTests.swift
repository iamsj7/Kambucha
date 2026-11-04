import Testing
import Foundation
@testable import MirrorCore

private func kit(_ kind: DestinationKind = .googleDrive, client: Bool = true) -> RecoveryKit {
    RecoveryKit(kind: kind, rootPath: "Mac Backup", passphrase: "test-passphrase-not-real", salt: "test-salt-not-real",
                filenameEncoding: kind == .oneDrive ? "base32768" : "base32", rcloneVersion: "v1.75.2",
                clientID: client ? "id-not-real.apps.example" : nil, clientSecret: client ? "secret-not-real" : nil)
}

/// Runs one line of the kit's restore steps through a real shell, against the vendored rclone.
private func shell(_ line: String, home: URL, conf: URL) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", line]
    let bin = home.appendingPathComponent("bin")
    p.environment = ["PATH": bin.path + ":/usr/bin:/bin", "HOME": home.path, "RCLONE_CONFIG": conf.path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run(); p.waitUntilExit()
    return p.terminationStatus
}

@Suite struct RecoveryKitTests {
    @Test func kitRoundTripsThroughText() throws {
        for k in [kit(), kit(.oneDrive), kit(.oneDrive, client: false)] {
            #expect(try RecoveryKit(parsing: k.text()) == k)
        }
    }

    @Test func generatedSecretsRoundTrip() throws {
        var k = kit()
        let v = VaultSecrets.generate()
        k.passphrase = v.passphrase; k.salt = v.salt
        #expect(try RecoveryKit(parsing: k.text()) == k)
    }

    @Test func parsingSurvivesHowPeopleMoveText() throws {
        let k = kit()
        let indented = k.text().split(separator: "\n", omittingEmptySubsequences: false).map { "   " + $0 + "  " }.joined(separator: "\r\n")
        #expect(try RecoveryKit(parsing: "Pasted from Notes:\n\n" + indented + "\n\nthanks") == k)
    }

    @Test func kitHasEverythingRecoveryNeeds() {
        let t = kit().text()
        for needed in ["googleDrive", "Mac Backup", "test-passphrase-not-real", "test-salt-not-real",
                       "standard", "base32", "v1.75.2", "id-not-real.apps.example", "secret-not-real",
                       "filename_encryption=standard", "directory_name_encryption=true", "filename_encoding=base32",
                       "--obscure", "scope=drive.file", "rclone copy"] {
            #expect(t.contains(needed), "missing \(needed)")
        }
        let one = kit(.oneDrive, client: false).text()
        #expect(one.contains("base32768") && one.contains("onedrive") && !one.contains("scope=drive.file"))
    }

    /// The steps in the document, run as written by plain rclone, with no Mirror code involved.
    @Test(arguments: [DestinationKind.googleDrive, .oneDrive])
    func kitStepsRestoreWithPlainRclone(kind: DestinationKind) async throws {
        let tmp = try TempDir()
        let home = try tmp.sub("home"), cloud = try tmp.sub("cloud"), src = try tmp.sub("src")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("bin/rclone"), withDestinationURL: vendoredRclone)
        let conf = tmp.url.appendingPathComponent("restore.conf")
        let vault = VaultSecrets.generate()   // hex: rclone would take it as already obscured without --obscure
        var k = kit(kind)
        k.passphrase = vault.passphrase; k.salt = vault.salt

        // Back up the way Mirror does: env-defined crypt.
        try "hello restore".write(to: src.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let env = try RcloneCrypt.environment(remote: "mirrorup", over: cloud.appendingPathComponent("Mac Backup").path, passphrase: k.passphrase, salt: k.salt,
                                              filenameEncoding: k.filenameEncoding, binary: vendoredRclone)
        #expect(try realRclone(["copy", src.path, "mirrorup:Mac Backup/Sets/s", "--config", "/dev/null"], env: env).code == 0)

        // Restore by the document: the cloud sign-in step is the only one that can't run here,
        // so a local alias stands in under the same remote name.
        let steps = k.text().split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("rclone ") }
        let signIn = try #require(steps.first { $0.contains("config create mirror-cloud") })
        #expect(signIn.contains(kind == .googleDrive ? " drive " : " onedrive "))
        #expect(try shell("rclone config create mirror-cloud alias remote='\(cloud.path)'", home: home, conf: conf) == 0)
        let crypt = try #require(steps.first { $0.contains("config create mirror-restore") })
        #expect(try shell(crypt, home: home, conf: conf) == 0)
        let copy = try #require(steps.first { $0.hasPrefix("rclone copy") })
        #expect(try shell(copy, home: home, conf: conf) == 0)

        let restored = home.appendingPathComponent("Restored/Sets/s/note.txt")
        #expect(try String(contentsOf: restored, encoding: .utf8) == "hello restore")
    }

    @Test func parsingRefusesBadTextWithoutEchoingIt() {
        let good = kit().text()
        let cases: [(String, RecoveryKitError)] = [
            ("nothing here", .notARecoveryKit),
            ("", .notARecoveryKit),
            (good.replacingOccurrences(of: "Passphrase: test-passphrase-not-real\n", with: ""), .missingField("Passphrase")),
            (good.replacingOccurrences(of: "Salt: test-salt-not-real", with: "Salt:   "), .missingField("Salt")),
            (good.replacingOccurrences(of: "Destination kind: googleDrive", with: "Destination kind: test-passphrase-not-real"), .unknownKind),
            (good.replacingOccurrences(of: "Salt: test-salt-not-real", with: "Salt: a\nSalt: b"), .duplicateField("Salt")),
            (good.replacingOccurrences(of: "Filename encoding: base32", with: "Filename encoding: test-salt-not-real"), .unsupportedEncryption),
            (good.replacingOccurrences(of: "Filename encryption: standard", with: "Filename encryption: off"), .unsupportedEncryption),
            (good.replacingOccurrences(of: "Directory name encryption: true", with: "Directory name encryption: false"), .unsupportedEncryption),
        ]
        for (text, expected) in cases {
            do { _ = try RecoveryKit(parsing: text); Issue.record("should refuse") }
            catch {
                #expect(error as? RecoveryKitError == expected)
                #expect(!"\(error)".contains("not-real"))
            }
        }
    }

    @Test func descriptionHidesSecrets() {
        let k = kit()
        for text in [String(describing: k), String(reflecting: k), "\(k)"] {
            #expect(!text.contains("test-passphrase") && !text.contains("test-salt") && !text.contains("secret-not-real"))
        }
    }

    @Test func madeFromStoredSecretsUsesDestinationSettings() throws {
        let secrets = MemorySecrets()
        let d = Destination(name: "One", kind: .oneDrive)
        let v = VaultSecrets.generate()
        try secrets.saveVault(v, for: d)
        try secrets.saveSignIn(["client_id": "cid", "client_secret": "cs", "token": "{}"], for: d)
        let k = try RecoveryKit.make(for: d, secrets: secrets, binary: vendoredRclone)
        #expect(k.kind == .oneDrive && k.rootPath == "Mac Backup" && k.filenameEncoding == "base32768")
        #expect(k.passphrase == v.passphrase && k.salt == v.salt && k.clientID == "cid" && k.clientSecret == "cs")
        #expect(k.rcloneVersion.hasPrefix("v1."))
    }

    @Test func noKitWithoutEncryptionOrKeys() throws {
        let secrets = MemorySecrets()
        #expect(throws: RcloneSessionError.encryptionNotSupported) {
            try RecoveryKit.make(for: Destination(name: "O", kind: .oneDrive, encrypted: false), secrets: secrets, binary: vendoredRclone)
        }
        #expect(throws: RcloneSessionError.encryptionKeysMissing) {
            try RecoveryKit.make(for: Destination(name: "O", kind: .oneDrive), secrets: secrets, binary: vendoredRclone)
        }
    }

    // MARK: - canSave

    private func set(_ url: URL) -> BackupSet { BackupSet(name: "s", source: url) }

    @Test func kitCannotBeSavedInsideSetSource() throws {
        let tmp = try TempDir()
        let src = try tmp.sub("src"), deep = try tmp.sub("src/a/b")
        let sets = [set(src)]
        #expect(!RecoveryKit.canSave(to: src.appendingPathComponent("kit.txt"), sets: sets))
        #expect(!RecoveryKit.canSave(to: deep.appendingPathComponent("kit.txt"), sets: sets))
        #expect(!RecoveryKit.canSave(to: src.appendingPathComponent("new/folder/kit.txt"), sets: sets))
        #expect(!RecoveryKit.canSave(to: src, sets: sets))
        #expect(RecoveryKit.canSave(to: tmp.url.appendingPathComponent("kit.txt"), sets: sets))
        #expect(RecoveryKit.canSave(to: tmp.url.appendingPathComponent("src2/kit.txt"), sets: sets))   // not a string prefix
        #expect(RecoveryKit.canSave(to: tmp.url.appendingPathComponent("kit.txt"), sets: []))
    }

    @Test func canSaveSeesThroughDotsCaseAndSymlinks() throws {
        let tmp = try TempDir()
        let src = try tmp.sub("Src"), other = try tmp.sub("other")
        let sets = [set(src)]
        #expect(!RecoveryKit.canSave(to: URL(fileURLWithPath: other.path + "/../Src/kit.txt"), sets: sets))
        #expect(!RecoveryKit.canSave(to: tmp.url.appendingPathComponent("SRC/kit.txt"), sets: sets))

        let alias = tmp.url.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: src)
        #expect(!RecoveryKit.canSave(to: alias.appendingPathComponent("kit.txt"), sets: sets))            // file doesn't exist yet
        #expect(!RecoveryKit.canSave(to: alias.appendingPathComponent("new/kit.txt"), sets: sets))
        #expect(RecoveryKit.canSave(to: other.appendingPathComponent("kit.txt"), sets: [set(alias)]))

        // A source named through a symlink still protects the real folder.
        #expect(!RecoveryKit.canSave(to: src.appendingPathComponent("kit.txt"), sets: [set(alias)]))

        // A file outside the source that is a link into it.
        let inside = src.appendingPathComponent("real.txt")
        try "x".write(to: inside, atomically: true, encoding: .utf8)
        let link = other.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
        #expect(!RecoveryKit.canSave(to: link, sets: sets))

        // A dangling link would create its target inside the source.
        let dangling = other.appendingPathComponent("dangling.txt")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: src.appendingPathComponent("not-yet.txt"))
        #expect(!RecoveryKit.canSave(to: dangling, sets: sets))
    }

    /// `/private/var` vs `/var`, and the Data-volume firmlink, name the same folder by different paths.
    @Test func canSaveComparesFilesystemIdentity() throws {
        let tmp = try TempDir()
        let src = try tmp.sub("src")
        let real = URL(fileURLWithPath: src.resolvingSymlinksInPath().path)
        let privatePath = real.path.hasPrefix("/private") ? real.path : "/private" + real.path
        let spellings = [privatePath, String(privatePath.dropFirst("/private".count)), "/System/Volumes/Data" + privatePath]
        for spelling in spellings where FileManager.default.fileExists(atPath: spelling) {
            for source in spellings where FileManager.default.fileExists(atPath: source) {
                let target = URL(fileURLWithPath: spelling).appendingPathComponent("not-yet/kit.txt")
                #expect(!RecoveryKit.canSave(to: target, sets: [set(URL(fileURLWithPath: source))]), "\(spelling) vs \(source)")
            }
        }
    }

    @Test func missingSourceStillRefusesByPath() throws {
        let tmp = try TempDir()
        let gone = tmp.url.appendingPathComponent("unmounted")
        #expect(!RecoveryKit.canSave(to: gone.appendingPathComponent("kit.txt"), sets: [set(gone)]))
    }
}
