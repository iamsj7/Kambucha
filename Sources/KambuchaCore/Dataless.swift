import Foundation

public enum Dataless {
    /// `SF_DATALESS`: the file's content is not on this Mac (a freed iCloud file).
    static let flag: UInt32 = 0x4000_0000

    /// Reads the flags with lstat so a symlink is judged as a link, never followed.
    /// A link, a missing file or an unreadable one is not dataless.
    public static func isDataless(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return isDataless(flags: st.st_flags, isLink: (st.st_mode & S_IFMT) == S_IFLNK)
    }

    static func isDataless(flags: UInt32, isLink: Bool) -> Bool {
        !isLink && (flags & flag) != 0
    }
}
