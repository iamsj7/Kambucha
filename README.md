# Kambucha

Kambucha is a Mac app that keeps a safe copy of the folders you choose. It copies them, one way, to iCloud Drive, Google Drive, OneDrive or an external drive. It lives in the menu bar and runs by itself every 30 minutes.

It is built for people who keep real work in project folders. It skips things you can rebuild, such as `node_modules`, and it keeps things you cannot rebuild, such as `.env` files and signing keys.

## What you get

- **You choose what is backed up.** Any folder, any kind of project. Kambucha suggests what to skip, shows you a preview, and you decide.
- **Old versions are kept.** A file you overwrite or delete on the Mac is moved to an archive in the destination, not destroyed. The archive is kept for 30 days by default.
- **Mass deletions are stopped.** If a run would delete a large number of files, Kambucha holds the deletions and asks you first. New and changed files still back up.
- **Honest status.** "Backed Up" is shown only when the copy was checked and the files really reached the destination.
- **Encryption for Google Drive and OneDrive.** Files and names are encrypted before they leave your Mac. You save a Recovery Kit, a document that can open the backup even if this Mac is gone.
- **Little disk and CPU use.** Copies into iCloud Drive share disk space with the originals, and nothing runs between backups.

## What it does not do

- It is not two-way sync. Changes made in the backup are overwritten.
- It does not back up iCloud Photos.
- It does not keep history beyond the archive window.
- It needs Full Disk Access, so it cannot be sold through the App Store.

## Requirements

- A Mac with Apple silicon (M1 or later).
- macOS 26 or later.

## Install

There is no download yet. You build the app yourself. The steps are in [docs/setup.md](docs/setup.md).

## Guides

- [docs/setup.md](docs/setup.md): install, permissions, adding a folder, reading each status, external drives, Google Drive and OneDrive.
- [docs/recovery.md](docs/recovery.md): getting your files back, including on a new Mac and without the app. Keep a copy of this guide somewhere that is not on this Mac.

## How it works, in short

Kambucha is two programs in one app. The menu bar app is what you see. A small background helper does the backing up, so backups continue even when the window is closed. Both use a copy of [rclone](https://rclone.org) that is bundled inside the app, and never any rclone you installed yourself. Passwords and sign-in tokens are kept only in your login Keychain.

The full design is in [docs/superpowers/specs/2026-11-04-icloud-mirror-design.md](docs/superpowers/specs/2026-11-04-icloud-mirror-design.md).
