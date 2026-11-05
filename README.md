# Kambucha

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 26+](https://img.shields.io/badge/macOS-26%2B-black)
![Apple silicon](https://img.shields.io/badge/Apple%20silicon-M1%2B-black)

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

## Project status

Kambucha is an early preview, so don't rely on it as your only backup yet.

| Area | Status |
|---|---|
| iCloud Drive backup, archive and restore | Tested on a real Mac with small folders |
| External drives | Built and covered by automated tests, not yet tried on a real drive |
| Google Drive and OneDrive | Built and covered by automated tests, not yet tried with real accounts |
| Very large folders | Not yet tested at full scale |
| Signed and notarized download | Not available yet |

## Install

There is no download yet, so you build the app yourself.

### Build from source

You need:

- A Mac with Apple silicon, running macOS 26 or later.
- Xcode with the macOS 26 SDK (Swift 6.2 or later).
- An Apple Development signing certificate. A free Apple account gives you one: in Xcode, open Settings, Accounts, then Manage Certificates.

Then run:

```sh
git clone https://github.com/iamsj7/Kambucha.git
cd Kambucha
scripts/fetch-rclone.sh     # downloads rclone and checks its checksum
scripts/build-app.sh        # builds and signs dist/Kambucha.app
scripts/verify-bundle.sh    # should finish with OK
```

If your Keychain has several signing identities, choose one first:

```sh
export KAMBUCHA_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"
```

Always sign with the same identity. macOS ties Full Disk Access to the signature, so a build signed differently loses that permission.

### Install and first run

Drag `dist/Kambucha.app` into `/Applications` and open it. The first-run screen walks you through background backups, Full Disk Access, notifications and your first folder. [docs/setup.md](docs/setup.md) covers each step.

### Uninstall

1. In Kambucha, open Settings and turn off Open Kambucha at login.
2. Quit Kambucha and delete it from `/Applications`.
3. To remove its settings and logs too, delete `~/Library/Application Support/Kambucha` and `~/Library/Logs/Kambucha`.
4. To remove saved sign-ins, open Keychain Access and delete the items named `com.shaikjaleel.kambucha`.

Your backups stay where they are, in the `Mac Backup` folder of each destination.

## Guides

- [docs/setup.md](docs/setup.md): install, permissions, adding a folder, reading each status, external drives, Google Drive and OneDrive.
- [docs/recovery.md](docs/recovery.md): getting your files back, including on a new Mac and without the app. Keep a copy of this guide somewhere that is not on this Mac.

## How it works, in short

Kambucha is two programs in one app. The menu bar app is what you see. A small background helper does the backing up, so backups continue even when the window is closed. Both use a copy of [rclone](https://rclone.org) that is bundled inside the app, and never any rclone you installed yourself. Passwords and sign-in tokens are kept only in your login Keychain.

## Contributing, security and credits

- [CONTRIBUTING.md](CONTRIBUTING.md): how to build, test and send changes.
- [SECURITY.md](SECURITY.md): how to report a problem privately, and how secrets are handled.
- [CREDITS.md](CREDITS.md): rclone and other acknowledgements.

## License

Kambucha is released under the [MIT License](LICENSE). It comes with no warranty, so keep more than one backup of anything you can't replace.
