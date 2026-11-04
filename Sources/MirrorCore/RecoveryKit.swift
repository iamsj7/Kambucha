import Foundation

/// Failures name a field at most. Pasted text is never repeated, because it holds the keys.
public enum RecoveryKitError: Error, Equatable {
    case notARecoveryKit, unknownKind, unsupportedEncryption
    case missingField(String), duplicateField(String)
}

/// Everything needed to open an encrypted destination without Mirror. It is meant to leave the Mac
/// as a document, so nothing in the app stores it, and its description hides the secrets.
public struct RecoveryKit: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                           CustomReflectable {
    public var kind: DestinationKind
    public var rootPath: String
    public var passphrase: String
    public var salt: String
    public var filenameEncoding: String
    public var rcloneVersion: String
    public var clientID: String?
    public var clientSecret: String?

    public init(kind: DestinationKind, rootPath: String, passphrase: String, salt: String, filenameEncoding: String,
                rcloneVersion: String, clientID: String?, clientSecret: String?) {
        self.kind = kind; self.rootPath = rootPath; self.passphrase = passphrase; self.salt = salt
        self.filenameEncoding = filenameEncoding; self.rcloneVersion = rcloneVersion
        self.clientID = clientID; self.clientSecret = clientSecret
    }

    /// The kit for a signed-in destination, from its Keychain items and the real rclone version.
    public static func make(for destination: Destination, secrets: any SecretStoring, binary: URL) throws -> RecoveryKit {
        guard destination.encrypted, let encoding = RcloneCrypt.filenameEncoding(for: destination.kind) else {
            throw RcloneSessionError.encryptionNotSupported
        }
        guard let vault = try secrets.vault(for: destination) else { throw RcloneSessionError.encryptionKeysMissing }
        let signIn = try secrets.signIn(for: destination)
        return RecoveryKit(kind: destination.kind, rootPath: MirrorPaths.rootFolderName, passphrase: vault.passphrase,
                           salt: vault.salt, filenameEncoding: encoding, rcloneVersion: try RcloneTool.version(binary: binary),
                           clientID: signIn?["client_id"], clientSecret: signIn?["client_secret"])
    }

    private enum Field {
        static let kind = "Destination kind", root = "Root path", passphrase = "Passphrase", salt = "Salt"
        static let filenames = "Filename encryption", directories = "Directory name encryption"
        static let encoding = "Filename encoding", client = "Client ID", secret = "Client secret"
        static let version = "rclone version"
    }
    private static let begin = "----- BEGIN MIRROR RECOVERY KIT -----"
    private static let end = "----- END MIRROR RECOVERY KIT -----"

    public func text() -> String {
        var fields = [(Field.kind, kind.rawValue), (Field.root, rootPath), (Field.passphrase, passphrase), (Field.salt, salt),
                      (Field.filenames, RcloneCrypt.filenameEncryption), (Field.directories, RcloneCrypt.directoryNameEncryption),
                      (Field.encoding, filenameEncoding)]
        if let clientID { fields.append((Field.client, clientID)) }
        if let clientSecret { fields.append((Field.secret, clientSecret)) }
        fields.append((Field.version, rcloneVersion))
        return """
            MIRROR RECOVERY KIT

            This document opens your encrypted backup. Without it, nobody can read that backup, \
            including you. With it, anyone can. Keep it somewhere safe, away from this Mac.

            \(Self.begin)
            \(fields.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
            \(Self.end)

            HOW TO RESTORE WITHOUT MIRROR

            \(restoreSteps())

            """
    }

    /// Plain rclone commands, kept runnable as written: a test executes them.
    private func restoreSteps() -> String {
        let cloud = "mirror-cloud", restore = "mirror-restore"
        let target = Self.quoted("\(cloud):\(rootPath)")
        let root = Self.quoted("\(restore):\(rootPath)/Sets")
        return """
            1. Install rclone from https://rclone.org/downloads/. This kit was made with \(rcloneVersion).

            2. Sign in. A browser opens: use the account that holds the backup.

                \(signInStep(remote: cloud))

            3. Describe the encryption. Keep --obscure: without it, rclone can take the passphrase \
            for an already-obscured value and fail to decrypt anything.

                rclone config create \(restore) crypt remote=\(target) \
            filename_encryption=\(RcloneCrypt.filenameEncryption) \
            directory_name_encryption=\(RcloneCrypt.directoryNameEncryption) filename_encoding=\(filenameEncoding) \
            password=\(Self.quoted(passphrase)) password2=\(Self.quoted(salt)) --obscure

            4. List your backup sets.

                rclone lsd \(root)

            5. Copy them back. To restore one set, add its name after Sets/ on both sides.

                rclone copy \(root) ~/Restored/Sets --links

            6. These commands hold your passphrase, so clear them from your shell history afterwards.
            """
    }

    private func signInStep(remote: String) -> String {
        var client = ""
        if let clientID { client += " client_id=\(Self.quoted(clientID))" }
        if let clientSecret { client += " client_secret=\(Self.quoted(clientSecret))" }
        switch kind {
        case .iCloudFolder:
            return "No sign-in is needed for this destination."
        case .googleDrive:
            return "rclone config create \(remote) drive scope=drive.file\(client)\n\n"
                + "   Use this same client ID and secret: Google only shows a client the files it created."
        case .oneDrive:
            return "rclone config create \(remote) onedrive\(client)"
        }
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Takes a whole pasted document. Only the lines between the markers count, so the restore steps
    /// or anything pasted around them can't be mistaken for fields.
    public init(parsing text: String) throws {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.firstIndex(of: Self.begin),
              let last = lines[first...].firstIndex(of: Self.end) else { throw RecoveryKitError.notARecoveryKit }

        var fields: [String: String] = [:]
        for line in lines[(first + 1)..<last] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            guard fields[label] == nil else { throw RecoveryKitError.duplicateField(label) }
            fields[label] = value
        }
        func required(_ label: String) throws -> String {
            guard let value = fields[label] else { throw RecoveryKitError.missingField(label) }
            return value
        }

        guard let kind = DestinationKind(rawValue: try required(Field.kind)) else { throw RecoveryKitError.unknownKind }
        let encoding = try required(Field.encoding)
        guard try required(Field.filenames) == RcloneCrypt.filenameEncryption,
              try required(Field.directories) == RcloneCrypt.directoryNameEncryption,
              ["base32", "base32768"].contains(encoding) else { throw RecoveryKitError.unsupportedEncryption }
        self.init(kind: kind, rootPath: try required(Field.root), passphrase: try required(Field.passphrase),
                  salt: try required(Field.salt), filenameEncoding: encoding, rcloneVersion: try required(Field.version),
                  clientID: fields[Field.client], clientSecret: fields[Field.secret])
    }

    /// False when `url` is inside any set's source, so the kit can't end up in the backup it unlocks.
    /// Paths alone can't show this: `/private/var` and `/var`, symlinks and the Data-volume firmlinks
    /// all name one folder differently. So existing folders are also compared by device and inode.
    public static func canSave(to url: URL, sets: [BackupSet]) -> Bool {
        guard let target = physicalPath(of: url) else { return false }   // a dangling link: where it writes is unclear
        let enclosing = Set(ancestors(of: target).compactMap(identity(of:)))
        return sets.allSatisfy { set in
            let source = physicalPath(of: set.source) ?? PathGuard.resolved(set.source)
            if PathGuard.isSameOrInside(target, source) { return false }
            return identity(of: source).map { !enclosing.contains($0) } ?? true
        }
    }

    /// Resolves the part of the path that exists, including `..` through symlinks, then adds the
    /// rest. `resolvingSymlinksInPath` won't do: it stops at a file that doesn't exist yet.
    private static func physicalPath(of url: URL) -> URL? {
        let parts = url.absoluteURL.path.split(separator: "/").map(String.init)
        for count in stride(from: parts.count, through: 0, by: -1) {
            let existing = "/" + parts.prefix(count).joined(separator: "/")
            var info = stat()
            guard lstat(existing, &info) == 0 else { continue }
            guard let real = realpath(existing, nil) else { return nil }
            defer { free(real) }
            var result = URL(fileURLWithPath: String(cString: real))
            for part in parts.dropFirst(count) {
                if part == ".." { result.deleteLastPathComponent() }
                else if part != "." { result.appendPathComponent(part) }
            }
            return result
        }
        return nil
    }

    private static func ancestors(of url: URL) -> [URL] {
        var all = [url]
        while let last = all.last, last.path != "/" { all.append(last.deletingLastPathComponent()) }
        return all
    }

    private struct FileIdentity: Hashable { let device: dev_t; let inode: ino_t }

    private static func identity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    public var description: String { "RecoveryKit(\(kind.rawValue), redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
