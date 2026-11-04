import Foundation

public enum MirrorPaths {
    public static let rootFolderName = "Mac Backup"

    /// From the user database. Foundation's home follows `CFFIXED_USER_HOME`, and the agent's
    /// environment comes from whoever spawned it, so that could point config and locks anywhere.
    public static var ownerHome: URL {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else {
            fatalError("No user database entry for the current user")
        }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
    }

    /// Drops what a caller could use to redirect Foundation or rclone. Call first thing in the agent.
    public static func scrubEnvironment() {
        unsetenv("CFFIXED_USER_HOME")
        unsetenv("TMPDIR")
        setenv("HOME", ownerHome.path, 1)
    }

    public static func iCloudDrive(home: URL = ownerHome) -> URL {
        home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }
    public static var iCloudDrive: URL { iCloudDrive() }

    public static func backupRoot(iCloudDrive: URL) -> URL {
        iCloudDrive.appendingPathComponent(rootFolderName, isDirectory: true)
    }
    public static var backupRoot: URL { backupRoot(iCloudDrive: iCloudDrive) }

    /// Relative to the backup root.
    public static func mirrorPath(_ set: BackupSet) -> String { "Sets/\(set.name)" }
    public static func archivePath(_ set: BackupSet, stamp: String) -> String { "Archive/\(set.name)/\(stamp)" }

    public static func support(home: URL = ownerHome) -> URL {
        home.appendingPathComponent("Library/Application Support/Mirror", isDirectory: true)
    }
    public static var support: URL { support() }

    public static func logs(home: URL = ownerHome) -> URL {
        home.appendingPathComponent("Library/Logs/Mirror", isDirectory: true)
    }
    public static var logs: URL { logs() }
}
