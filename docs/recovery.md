# Getting your files back

Take a breath. If you are reading this because something went wrong, your backup is very likely fine, and nothing here needs to be done fast, with one exception: old versions and deleted files are kept in the archive for 30 days by default (see "Undoing a mass deletion").

Three rules that keep you safe:

1. **Restore folders to a new, empty folder first.** Never restore a folder on top of your working folder. Look at the result, then move files into place. A single deleted file can go straight back where it was.
2. **Do not delete anything in the backup.** Not in iCloud Drive, not in Google Drive or OneDrive, not on the external drive.
3. **Copy and paste commands exactly.** Lines starting with `$` are what you type, without the `$`. Anything in `<angle brackets>` is for you to fill in.

Print this guide, or keep a copy away from your Mac. If you use Google Drive or OneDrive, your Recovery Kit is the other thing you must have.

## Contents

1. Where your backup lives
2. Get rclone (only if you do not have the app)
3. Restore one deleted or overwritten file
4. Restore a whole project
5. Rebuild on a new Mac
6. Google Drive and OneDrive: open the backup with the Recovery Kit
7. Symlinks, `--links` and the manifest
8. Reinstall dependencies
9. Undo a mass deletion
10. Check your result

## 1. Where your backup lives

Every destination has the same layout inside a folder called `Mac Backup`.

    Mac Backup/
      Sets/<set name>/                      the current copy of each folder
      Archive/<set name>/<timestamp>/       old versions and deleted files
      Manifests/<set name>.json             list of symlinks (see below)

| Destination | `Mac Backup` is here | Readable by eye? |
|---|---|---|
| iCloud folder | `~/Library/Mobile Documents/com~apple~CloudDocs/Mac Backup`. In Finder: iCloud Drive, then Mac Backup | Yes |
| External drive | `/Volumes/<drive name>/Mac Backup` | Yes |
| Google Drive | In your Google Drive, in a folder made by Kambucha | No. File and folder names are scrambled. Use rclone. |
| OneDrive | In your OneDrive | No. Same as Google Drive. |

The `<timestamp>` folders look like `2026-11-04T10-00-30`, and they are in UTC, not your local time. Allow for that when you look for a run by its time.

`Manifests` exists only on the iCloud folder and on drives formatted APFS or Mac OS Extended. Google Drive, OneDrive and exFAT drives keep symlinks as files inside `Sets`, so they need no list (see section 7).

Google Drive and OneDrive backups are encrypted by default, so opening them in a web browser shows meaningless names and files. That is normal. Section 6 opens them. If you turned encryption off for a destination, the names are readable, and you can still use the commands in section 6 without the encryption step by pointing rclone straight at that account.

## 2. Get rclone (only if you do not have the app)

rclone is the free tool Kambucha uses. It runs from Terminal.

- If Kambucha is installed, you already have it: `/Applications/Kambucha.app/Contents/Helpers/rclone`.
- Otherwise, download it from <https://rclone.org/downloads/>. Choose macOS, Apple silicon (arm64), unzip it, and note the path to the `rclone` file. If macOS refuses to open it, go to System Settings, Privacy & Security, and choose Open Anyway for rclone.

The Recovery Kit says which version made your backup. A newer version works too.

In the commands below, `rclone` means whichever one you have. The easiest way is to make a shortcut for this Terminal window only:

    $ alias rclone='/Applications/Kambucha.app/Contents/Helpers/rclone'

or, for a download in your Downloads folder:

    $ alias rclone="$HOME/Downloads/rclone-v1.75.2-osx-arm64/rclone"

Check that it works:

    $ rclone version

Set up shortcuts for your backup folder (use whichever matches your destination):

    $ BACKUP="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Mac Backup"
    $ BACKUP="/Volumes/<drive name>/Mac Backup"

For Google Drive and OneDrive there is no folder to point at. Section 6 gives you a name instead, `kambucha-restore:`, that works in place of `"$BACKUP/"` in the rclone commands.

## 3. Restore one deleted or overwritten file

### Newest copy, or a file deleted by mistake very recently

The newest copy is in `Sets/<set name>/`. A file you deleted or overwrote is in `Archive/` instead.

### With the app (any destination)

1. Open Kambucha, then Archive in the sidebar, and choose the set and the destination at the top.
2. For a file you deleted or overwrote, stay on Older Versions. Files are grouped by the backup run that moved them, then by folder. Use the search field to find a file across all your sets. Choose Restore next to the one you want.
3. For the newest copy of a file, choose Latest Backup, open the folders down to it, and choose Restore next to it.
4. For a single file, the save window opens in the folder it came from. Choose Restore to put it back, or pick another place to keep both copies. If a file with that name is there, macOS asks before replacing it. A whole folder must go to a new place, as Kambucha will not restore a folder into one it backs up.

Kambucha restores through rclone, so symlinks come back correctly. Files that iCloud has freed to save space are downloaded as needed.

### iCloud folder or external drive, without the app

Using Finder: open the `Mac Backup` folder, then `Archive`, then your set, then the date folder, and drag the file out. Use `Sets` for the newest copy.

Using Terminal, first look at what is there:

    $ ls "$BACKUP/Archive/<set name>/"

Each folder is one run that moved files away. Open them to find yours:

    $ rclone lsf -R "$BACKUP/Archive/<set name>/<timestamp>" | grep "<part of the file name>"

Copy one file to a new folder:

    $ mkdir -p ~/Restored
    $ rclone copyto "$BACKUP/Archive/<set name>/<timestamp>/<path to file>" ~/Restored/<file name>

For the newest copy use `"$BACKUP/Sets/<set name>/<path to file>"` instead.

On iCloud, a file may show as a cloud icon and not yet be on the Mac. rclone and Finder both download it when asked. It can take a moment.

### Google Drive or OneDrive, without the app

First do section 6, so that `kambucha-restore:` exists. Then:

    $ rclone lsf -R kambucha-restore:Archive/<set name> | grep "<part of the file name>"
    $ rclone copyto "kambucha-restore:Archive/<set name>/<timestamp>/<path to file>" ~/Restored/<file name>

## 4. Restore a whole project

The project is a folder inside the set. The set is the folder you chose when you set up the backup, and the project is a folder inside it.

### With the app

1. Open Kambucha, then Archive in the sidebar, and choose the set and the destination at the top.
2. Choose Latest Backup.
3. Choose Restore next to the project folder. To restore a folder deeper down, open the folders and choose Restore This Folder. At the top of the set, the same button is Restore Whole Set.
4. Type a new name for the restored folder and choose where to put it. Kambucha will not restore into a folder it backs up, or over a folder that already has files in it.

### iCloud folder or external drive, without the app

First wait until iCloud Drive has finished (see section 5) if this is a new Mac. Then:

    $ rclone copy "$BACKUP/Sets/<set name>/<project folder>" ~/Restored/<project folder> --links --progress

### Google Drive or OneDrive, without the app

After section 6:

    $ rclone copy "kambucha-restore:Sets/<set name>/<project folder>" ~/Restored/<project folder> --links --progress

To restore a whole set, leave off the project folder. To restore everything, use `kambucha-restore:Sets` and `~/Restored/Sets`.

Add `--dry-run` to any copy to see what it would do without doing it.

Do not forget `--links`. Section 7 explains why. Then do sections 7 and 8 for symlinks and dependencies.

## 5. Rebuild on a new Mac

### iCloud folder

1. Sign in to the same Apple Account (System Settings, then your name).
2. Turn on iCloud Drive.
3. Wait. Open Finder, then iCloud Drive, and check that `Mac Backup` appears. Large backups take a long time to appear in full. Let the Mac stay on and connected. Do not restore until the status shows no more downloading.
4. Follow section 4 "without the app", using the iCloud folder path in section 1. The app's Archive lists only the sets on this Mac, so it can't restore a set this Mac has not backed up. If you have installed Kambucha, its rclone is already there (section 2).

Do not add the old set again as a new backup right away. First restore, then check the result. When you do add the restored folder under its old name, Kambucha tells you the name is still in use by a backup in that destination. Choose Use Existing Backup to carry on from it: Kambucha compares, copies what changed, and moves anything that isn't in the folder to the archive. Or choose a different name to start a fresh backup beside the old one, which stays where it is.

### External drive

Plug the drive in. If it has a password, unlock it. Follow section 4 with `BACKUP="/Volumes/<drive name>/Mac Backup"`.

### Google Drive or OneDrive

You need two things: your Recovery Kit, and the ability to sign in to the same Google or Microsoft account. You do not need the Kambucha app, and you do not need the old Mac.

Go to section 6.

## 6. Google Drive and OneDrive: open the backup with the Recovery Kit

Your Recovery Kit is a text document. Inside it, between the lines `BEGIN KAMBUCHA RECOVERY KIT` and `END KAMBUCHA RECOVERY KIT`, are your values. The Kit itself also has restore steps. This section is the same procedure, explained.

### With the app

This puts the destination back on this Mac, so Kambucha can carry on backing up to it. Do it after you have your files back.

1. Install Kambucha and open it.
2. Choose the plus button, then Add Destination, and choose Google Drive or OneDrive.
3. Choose I Have a Recovery Kit. Do not choose Sign In, which makes new keys.
4. Paste the whole Recovery Kit and choose Restore. A browser opens. Sign in to the same account.
5. Add your restored folder as a set, using its old name, and choose Use Existing Backup when Kambucha says the name is in use (section 5).

The app's Archive lists only the sets on this Mac, so on a new Mac use "Without the app" below to get your files back first.

If a destination on this Mac has lost its keys, choose Restore From Recovery Kit on its screen.

If Kambucha asks you to paste the Kit as a test ("restore test"), that only checks the Kit. Passing it means your Kit works.

### Without the app, using only plain rclone

This works on any Mac, with only the Kit and the right account.

**Step 1: Sign in.** The Kit gives you the exact line. For Google Drive it looks like this:

    $ rclone config create kambucha-cloud drive scope=drive.file client_id='<Client ID from the Kit>' client_secret='<Client secret from the Kit>'

A browser opens. Sign in with the account that holds the backup and allow access. You must use the same client ID and secret from the Kit. Google shows a client only the files that client created, so a different client would see an empty Drive.

For OneDrive:

    $ rclone config create kambucha-cloud onedrive

Sign in with the Microsoft account that holds the backup. If the Kit lists a client ID, add it as `client_id='...' client_secret='...'` to the same line.

**Step 2: Describe the encryption.** Copy the values from the Kit.

    $ rclone config create kambucha-restore crypt remote='kambucha-cloud:Mac Backup' filename_encryption=standard directory_name_encryption=true filename_encoding=<base32 or base32768> password='<Passphrase from the Kit>' password2='<Salt from the Kit>' --obscure

Notes:

- The filename encoding is on the Kit's "Filename encoding" line. It is `base32` for Google Drive and `base32768` for OneDrive. A wrong value makes every file look missing.
- Keep `--obscure`. Without it, rclone can take the passphrase for an already-scrambled value and then fail to decrypt anything.
- Keep the single quotes. The Kit's passphrase and salt are 64 letters and digits.
- The first line `remote='kambucha-cloud:Mac Backup'` is correct as written. The name `Mac Backup` is the root folder, and `Sets` and `Archive` sit directly under `kambucha-restore:`.

**Step 3: Look.**

    $ rclone lsd kambucha-restore:Sets

You should see the names of your sets. If you see nothing, or an error about decrypting, see "If it does not work" below.

    $ rclone lsd kambucha-restore:Sets/<set name>

**Step 4: Copy back.**

    $ rclone copy kambucha-restore:Sets ~/Restored/Sets --links --progress

To restore just one set or project, add its name to both sides:

    $ rclone copy "kambucha-restore:Sets/<set name>/<project folder>" ~/Restored/Sets/<set name>/<project folder> --links --progress

Archive works the same way, for example `kambucha-restore:Archive/<set name>`.

**Step 5: Clean up.** These commands hold your passphrase, and your rclone settings now hold your keys. When you are done:

    $ rclone config delete kambucha-restore
    $ rclone config delete kambucha-cloud

Then quit Terminal. Your shell remembers what you typed, including the passphrase. To forget all of it, run `rm -f ~/.zsh_history` after quitting Terminal, then open it again.

Close the Terminal window. If you want to keep working with the backup, leave the settings in place, but know that they let anyone using your account on this Mac open the backup.

Do not paste the contents of your Recovery Kit into chat tools, emails or anywhere else.

### If it does not work

| What you see | Likely reason | What to do |
|---|---|---|
| `rclone lsd` shows nothing | Wrong account, or a different Google client than the Kit's | Check the account. Redo Step 1 with the Kit's client ID and secret. |
| `directory not found` when listing `kambucha-restore:Sets` | Wrong passphrase or salt, or `--obscure` was left off. rclone cannot tell a wrong key from a missing folder | Run `rclone config delete kambucha-restore`, then redo Step 2, copying the values again from the Kit. |
| `Skipping undecryptable dir name` | Wrong filename encoding | Redo Step 2 with the encoding from the Kit. |
| Everything is listed but names look scrambled | You are looking at `kambucha-cloud:`, not `kambucha-restore:` | Use `kambucha-restore:`. |
| Sign-in error from Microsoft mentioning `AADSTS65005` | Your organisation blocks rclone | Use a personal Microsoft account, or ask your administrator. |
| Google says access blocked | The Google project may be back in Testing, or you used the wrong client | Check the project's Publishing status is In production. Use the Kit's client. |

## 7. Symlinks, `--links` and the manifest

A symlink is a shortcut file that points to another file or folder. Projects have many, for example in `node_modules/.bin`.

### How each destination stores symlinks

- iCloud folder, and external drives formatted APFS or Mac OS Extended: real symlinks.
- Google Drive, OneDrive, and exFAT drives: a small file named like `link.rclonelink`, holding the target as text. These services and exFAT cannot hold a symlink.

### Why you must use `--links`

`--links` tells rclone to treat symlinks as symlinks. It turns `.rclonelink` files back into real symlinks, and it copies real symlinks as symlinks.

Without `--links` you get these results:

- From Google Drive, OneDrive or exFAT, you get the plain `.rclonelink` text files and no symlinks.
- From iCloud or an APFS drive, rclone skips every symlink and prints `Can't follow symlink without -L/--copy-links`.

So add `--links` to every `rclone copy` of a project. It is safe to use even when there are no symlinks.

Do not use `:local,links:` as the source in a command. Use the plain folder with `--links`, as in this guide.

### Check your symlinks came back

    $ find ~/Restored -type l | head
    $ find ~/Restored -name '*.rclonelink' | head

The first should list your links. The second should list nothing.

### Restoring symlinks from the manifest

This applies to the iCloud folder and to drives formatted APFS or Mac OS Extended. Google Drive, OneDrive and exFAT drives have no manifest, as their `.rclonelink` files are the record.

iCloud stores symlinks in a way that could not be fully proven from one Mac. So each run also saves a list of every symlink in the set, at `Mac Backup/Manifests/<set name>.json`. Each entry has a relative path and the target. If a symlink is missing after a restore, recreate it from the list.

The Kambucha app does this for you when you restore. By hand:

1. Copy the manifest next to your restored files.

        $ cp "$BACKUP/Manifests/<set name>.json" ~/manifest.json

2. Move into the restored set folder and run this. It only makes links that are missing, and never changes a file that exists.

        $ cd ~/Restored/Sets/<set name>
        $ /usr/bin/jq -c '.[]' ~/manifest.json | while IFS= read -r row; do
            p=$(printf %s "$row" | /usr/bin/jq -r .path)
            t=$(printf %s "$row" | /usr/bin/jq -r .target)
            if [ ! -e "$p" ] && [ ! -L "$p" ]; then
              mkdir -p "$(dirname "$p")" && ln -s "$t" "$p" && echo "made $p"
            fi
          done

Some links point at things outside the project, or at nothing. That is how they were on your Mac. They are restored as they were, and a link that points nowhere is not an error.

## 8. Reinstall dependencies

Kambucha does not back up folders that can be rebuilt, such as `node_modules`. After a restore, rebuild them. Run the matching command inside each restored project.

| Project has | Run |
|---|---|
| `package-lock.json` | `npm ci` |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| `yarn.lock` | `yarn install --frozen-lockfile` |
| `bun.lock` or `bun.lockb` | `bun install` |
| `pubspec.yaml` (Flutter or Dart) | `flutter pub get` (or `dart pub get`) |
| `ios/Podfile` or `Podfile` | `pod install` (in the folder with the Podfile) |
| `composer.json` | `composer install` |
| `requirements.txt` | `python3 -m venv .venv`, then `.venv/bin/pip install -r requirements.txt` |
| `pyproject.toml` with Poetry | `poetry install` |
| `Gemfile` | `bundle install` |
| `Cargo.toml` | `cargo build` |
| `go.mod` | `go mod download` |
| `build.gradle` (Android) | `./gradlew build` |
| `*.csproj` | `dotnet restore` |
| Xcode project | Open it in Xcode. It rebuilds DerivedData and Swift packages. |

Use the lock file commands (`npm ci` and similar) so that you get the exact versions you had.

Also check:

- **Git:** `git status` inside a project. Git history is included unless you switched it off for that set. If a project has no `.git` folder, history was not backed up.
- **Scripts:** if a script says `permission denied`, run `chmod +x <script>`. Some destinations do not keep the executable flag.
- **Secrets:** your `.env` files and keys are backed up by default. Check that the ones you need are there before you remove anything from the old Mac.

## 9. Undo a mass deletion

Kambucha makes a mass deletion hard to do by accident, and easy to undo.

### If Kambucha says "N deletions held"

Nothing has been deleted from the backup. Kambucha holds only the deletions. New and changed files keep backing up.

1. Choose Review Deletions.
2. Read the list of files. If you removed them on purpose, choose Allow Once. If it is a mistake, such as a folder that moved, a drive that did not mount or a wrong command, choose Keep Holding.
3. Fix the problem on your Mac. For example, move the folder back. The next backup sees the files again and the hold clears.

### If the deletion already went through

The files are in the archive, not gone. The archive keeps them 30 days by default, so act within that time.

1. **Pause backups** in the menu bar, so no further runs change the archive.
2. Find the run that deleted them. Each run that moved files makes one dated folder. Look at the dates around the time of the problem, remembering they are in UTC.

   iCloud folder or external drive:

        $ ls "$BACKUP/Archive/<set name>/"

   Google Drive or OneDrive (after section 6):

        $ rclone lsd kambucha-restore:Archive/<set name>

3. Check what is inside.

        $ rclone lsf -R "$BACKUP/Archive/<set name>/<timestamp>" | head -50

   or with `kambucha-restore:Archive/<set name>/<timestamp>`.

4. Restore to a new folder. If several runs deleted files, restore each one into the same new folder, newest first, adding `--ignore-existing` so that an older copy never replaces a newer one.

        $ rclone copy "$BACKUP/Archive/<set name>/<timestamp>" ~/Restored/Undo --links --ignore-existing --progress

5. Look in `~/Restored/Undo`. When it is right, move the files back to their original place.
6. Choose Resume in the menu bar. The next backup copies the files back to the destination.

With the app: open Archive and choose the set and the destination. Under Older Versions, find a file from that run, Control-click it and choose Restore Everything From This Run. Give the restored folder a new name. Do this once for each run, into separate folders, and move the files back by hand.

If something in the archive is older than 30 days, it is gone from the archive, but it may still be in the current copy in `Sets/`, if it was not removed there.

## 10. Check your result

Compare a restored folder with the backup:

iCloud folder or external drive:

    $ rclone check "$BACKUP/Sets/<set name>/<project folder>" ~/Restored/<project folder> --links --size-only

Google Drive or OneDrive:

    $ rclone check "kambucha-restore:Sets/<set name>/<project folder>" ~/Restored/<project folder> --links --size-only

`0 differences found` means every file is there with the right size. A line saying `No common hash found` is expected here and is not a problem. Sizes cannot show an unchanged-size edit, but this is a good first check. To compare contents of a few files by eye, open them.

Things that are not backed up by design, so they will not match a comparison with your old Mac: rebuildable folders like `node_modules`, `.DS_Store` files, and anything your own rules skipped.
