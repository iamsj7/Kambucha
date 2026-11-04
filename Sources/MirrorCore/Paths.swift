import Foundation

public enum MirrorPaths {
    public static let rootFolderName = "Mac Backup"

    public static func iCloudDrive(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
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

    public static func support(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Mirror", isDirectory: true)
    }
    public static var support: URL { support() }

    public static func logs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Logs/Mirror", isDirectory: true)
    }
    public static var logs: URL { logs() }
}
