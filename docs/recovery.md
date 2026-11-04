# Getting your files back

Take a breath. If you are reading this because something went wrong, your backup is very likely fine, and nothing here needs to be done fast, with one exception: old versions and deleted files are kept in the archive for 30 days by default (see "Undoing a mass deletion").

Three rules that keep you safe:

1. **Restore to a new, empty folder first.** Never restore on top of your working folder. Look at the result, then move files into place.
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
      Manifests/<set name>.json             list of symlinks

| Destination | `Mac Backup` is here | Readable by eye? |
|---|---|---|
| iCloud folder | `~/Library/Mobile Documents/com~apple~CloudDocs/Mac Backup`. In Finder: iCloud Drive, then Mac Backup | Yes |
| External drive | `/Volumes/<drive name>/Mac Backup` | Yes |
| Google Drive | In your Google Drive, in a folder made by Mirror | No. File and folder names are scrambled. Use rclone. |
| OneDrive | In your OneDrive | No. Same as Google Drive. |

Google Drive and OneDrive backups are encrypted by default, so opening them in a web browser shows meaningless names and files. That is normal. Section 6 opens them. If you turned encryption off for a destination, the names are readable, and you can still use the commands in section 6 without the encryption step by pointing rclone straight at that account.

## 2. Get rclone (only if you do not have the app)

rclone is the free tool Mirror uses. It runs from Terminal.

- If Mirror is installed, you already have it: `/Applications/Mirror.app/Contents/Helpers/rclone`.
- Otherwise, download it from <https://rclone.org/downloads/>. Choose macOS, Apple silicon (arm64), unzip it, and note the path to the `rclone` file. If macOS refuses to open it, go to System Settings, Privacy & Security, and choose Open Anyway for rclone.

The Recovery Kit says which version made your backup. A newer version works too.

In the commands below, `rclone` means whichever one you have. The easiest way is to make a shortcut for this Terminal window only:

    $ alias rclone='/Applications/Mirror.app/Contents/Helpers/rclone'

or, for a download in your Downloads folder:

    $ alias rclone="$HOME/Downloads/rclone-v1.75.2-osx-arm64/rclone"

Check that it works:

    $ rclone version

Set up shortcuts for your backup folder (use whichever matches your destination):

    $ BACKUP="$HOME/Library/Mobile Documents/com~apple~CloudDocs/Mac Backup"
    $ BACKUP="/Volumes/<drive name>/Mac Backup"

For Google Drive and OneDrive there is no folder to point at. Section 6 gives you a name instead, `mirror-restore:`, that works in place of `"$BACKUP/"` in the rclone commands.

## 3. Restore one deleted or overwritten file

### Newest copy, or a file deleted by mistake very recently

The newest copy is in `Sets/<set name>/`. A file you deleted or overwrote is in `Archive/` instead.

### With the app (any destination)

1. Open Mirror, then Archive in the sidebar.
2. Choose the set and the date.
3. Select the file or folder and choose Restore. Pick a new folder as the place to put it.

Mirror restores through rclone, so symlinks come back correctly. Files that iCloud has freed to save space are downloaded as needed.

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

First do section 6, so that `mirror-restore:` exists. Then:

    $ rclone lsf -R mirror-restore:Archive/<set name> | grep "<part of the file name>"
    $ rclone copyto "mirror-restore:Archive/<set name>/<timestamp>/<path to file>" ~/Restored/<file name>

## 4. Restore a whole project

The project is a folder inside the set. The set is the folder you chose when you set up the backup, and the project is a folder inside it.

### With the app

Open Archive or the set, choose the project folder, and Restore it to a new folder.

### iCloud folder or external drive, without the app

First wait until iCloud Drive has finished (see section 5) if this is a new Mac. Then:

    $ rclone copy "$BACKUP/Sets/<set name>/<project folder>" ~/Restored/<project folder> --links --progress

### Google Drive or OneDrive, without the app

After section 6:

    $ rclone copy "mirror-restore:Sets/<set name>/<project folder>" ~/Restored/<project folder> --links --progress

To restore a whole set, leave off the project folder. To restore everything, use `mirror-restore:Sets` and `~/Restored/Sets`.

Add `--dry-run` to any copy to see what it would do without doing it.

Do not forget `--links`. Section 7 explains why. Then do sections 7 and 8 for symlinks and dependencies.

## 5. Rebuild on a new Mac

### iCloud folder

1. Sign in to the same Apple Account (System Settings, then your name).
2. Turn on iCloud Drive.
3. Wait. Open Finder, then iCloud Drive, and check that `Mac Backup` appears. Large backups take a long time to appear in full. Let the Mac stay on and connected. Do not restore until the status shows no more downloading.
4. With the app: install Mirror ([setup guide](setup.md)), give it Full Disk Access, and restore from Archive or the set. Without the app: follow section 4 using the iCloud folder path in section 1.

Do not add the old set again as a new backup right away. First restore, then check the result. If you point Mirror at a restored folder later, it will compare and carry on.

### External drive

Plug the drive in. If it has a password, unlock it. Follow section 4 with `BACKUP="/Volumes/<drive name>/Mac Backup"`.

### Google Drive or OneDrive

You need two things: your Recovery Kit, and the ability to sign in to the same Google or Microsoft account. You do not need the Mirror app, and you do not need the old Mac.

Go to section 6.

## 6. Google Drive and OneDrive: open the backup with the Recovery Kit

Your Recovery Kit is a text document. Inside it, between the lines `BEGIN MIRROR RECOVERY KIT` and `END MIRROR RECOVERY KIT`, are your values. The Kit itself also has restore steps. This section is the same procedure, explained.

### With the app

1. Install Mirror and open it.
2. Open Destinations, choose Add Destination, and sign in to the same account.
3. When asked for your keys, paste the whole Recovery Kit.
4. The destination then appears with its sets and archive. Restore as in sections 3 and 4.

If Mirror asks you to paste the Kit as a test ("restore drill"), that is the same step. Passing it means your Kit works.

### Without the app, using only plain rclone

This works on any Mac, with only the Kit and the right account.

**Step 1: Sign in.** The Kit gives you the exact line. For Google Drive it looks like this:

    $ rclone config create mirror-cloud drive scope=drive.file client_id='<Client ID from the Kit>' client_secret='<Client secret from the Kit>'

A browser opens. Sign in with the account that holds the backup and allow access. You must use the same client ID and secret from the Kit. Google shows a client only the files that client created, so a different client would see an empty Drive.

For OneDrive:

    $ rclone config create mirror-cloud onedrive

Sign in with the Microsoft account that holds the backup. If the Kit lists a client ID, add it as `client_id='...' client_secret='...'` to the same line.

**Step 2: Describe the encryption.** Copy the values from the Kit.

    $ rclone config create mirror-restore crypt remote='mirror-cloud:Mac Backup' filename_encryption=standard directory_name_encryption=true filename_encoding=<base32 or base32768> password='<Passphrase from the Kit>' password2='<Salt from the Kit>' --obscure

Notes:

- The filename encoding is on the Kit's "Filename encoding" line. It is `base32` for Google Drive and `base32768` for OneDrive. A wrong value makes every file look missing.
- Keep `--obscure`. Without it, rclone can take the passphrase for an already-scrambled value and then fail to decrypt anything.
- Keep the single quotes. The Kit's passphrase and salt are 64 letters and digits.
- The first line `remote='mirror-cloud:Mac Backup'` is correct as written. The name `Mac Backup` is the root folder, and `Sets`, `Archive` and `Manifests` sit directly under `mirror-restore:`.

**Step 3: Look.**

    $ rclone lsd mirror-restore:Sets

You should see the names of your sets. If you see nothing, or an error about decrypting, see "If it does not work" below.

    $ rclone lsd mirror-restore:Sets/<set name>

**Step 4: Copy back.**

    $ rclone copy mirror-restore:Sets ~/Restored/Sets --links --progress

To restore just one set or project, add its name to both sides:

    $ rclone copy "mirror-restore:Sets/<set name>/<project folder>" ~/Restored/Sets/<set name>/<project folder> --links --progress

Archive works the same way, for example `mirror-restore:Archive/<set name>`.

**Step 5: Clean up.** These commands hold your passphrase, and your rclone settings now hold your keys. When you are done:

    $ rclone config delete mirror-restore
    $ rclone config delete mirror-cloud

Then quit Terminal. Your shell remembers what you typed, including the passphrase. To forget all of it, run `rm -f ~/.zsh_history` after quitting Terminal, then open it again.

Close the Terminal window. If you want to keep working with the backup, leave the settings in place, but know that they let anyone using your account on this Mac open the backup.

Do not paste the contents of your Recovery Kit into chat tools, emails or anywhere else.

### If it does not work

| What you see | Likely reason | What to do |
|---|---|---|
| `rclone lsd` shows nothing | Wrong account, or a different Google client than the Kit's | Check the account. Redo Step 1 with the Kit's client ID and secret. |
| `directory not found` when listing `mirror-restore:Sets` | Wrong passphrase or salt, or `--obscure` was left off. rclone cannot tell a wrong key from a missing folder | Run `rclone config delete mirror-restore`, then redo Step 2, copying the values again from the Kit. |
| `Skipping undecryptable dir name` | Wrong filename encoding | Redo Step 2 with the encoding from the Kit. |
| Everything is listed but names look scrambled | You are looking at `mirror-cloud:`, not `mirror-restore:` | Use `mirror-restore:`. |
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

iCloud stores symlinks in a way that could not be fully proven from one Mac. So each run also saves a list of every symlink in the set, at `Mac Backup/Manifests/<set name>.json`. Each entry has a relative path and the target. If a symlink is missing after a restore, recreate it from the list.

The Mirror app does this for you when you restore. By hand:

1. Copy the manifest next to your restored files.

   iCloud or external drive:

        $ cp "$BACKUP/Manifests/<set name>.json" ~/manifest.json

   Google Drive or OneDrive (after section 6):

        $ rclone copyto "mirror-restore:Manifests/<set name>.json" ~/manifest.json

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

Mirror does not back up folders that can be rebuilt, such as `node_modules`. After a restore, rebuild them. Run the matching command inside each restored project.

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

Mirror makes a mass deletion hard to do by accident, and easy to undo.

### If Mirror says "N deletions held"

Nothing has been deleted from the backup. Mirror holds only the deletions. New and changed files keep backing up.

1. Choose Review Deletions.
2. Read the list of files. If you removed them on purpose, choose Allow Once. If it is a mistake, such as a folder that moved, a drive that did not mount or a wrong command, choose Keep Holding.
3. Fix the problem on your Mac. For example, move the folder back. The next backup sees the files again and the hold clears.

### If the deletion already went through

The files are in the archive, not gone. The archive keeps them 30 days by default, so act within that time.

1. **Pause backups** in the menu bar, so no further runs change the archive.
2. Find the run that deleted them. Each run that moved files makes one dated folder. Look at the dates around the time of the problem.

   iCloud folder or external drive:

        $ ls "$BACKUP/Archive/<set name>/"

   Google Drive or OneDrive (after section 6):

        $ rclone lsd mirror-restore:Archive/<set name>

3. Check what is inside.

        $ rclone lsf -R "$BACKUP/Archive/<set name>/<timestamp>" | head -50

   or with `mirror-restore:Archive/<set name>/<timestamp>`.

4. Restore to a new folder. If several runs deleted files, restore each one into the same new folder, newest first, adding `--ignore-existing` so that an older copy never replaces a newer one.

        $ rclone copy "$BACKUP/Archive/<set name>/<timestamp>" ~/Restored/Undo --links --ignore-existing --progress

5. Look in `~/Restored/Undo`. When it is right, move the files back to their original place.
6. Choose Resume in the menu bar. The next backup copies the files back to the destination.

With the app: open Archive, choose the set and the date, and restore to a new folder.

If something in the archive is older than 30 days, it is gone from the archive, but it may still be in the current copy in `Sets/`, if it was not removed there.

## 10. Check your result

Compare a restored folder with the backup:

iCloud folder or external drive:

    $ rclone check "$BACKUP/Sets/<set name>/<project folder>" ~/Restored/<project folder> --links --size-only

Google Drive or OneDrive:

    $ rclone check "mirror-restore:Sets/<set name>/<project folder>" ~/Restored/<project folder> --links --size-only

`0 differences found` means every file is there with the right size. A line saying `No common hash found` is expected here and is not a problem. Sizes cannot show an unchanged-size edit, but this is a good first check. To compare contents of a few files by eye, open them.

Things that are not backed up by design, so they will not match a comparison with your old Mac: rebuildable folders like `node_modules`, `.DS_Store` files, and anything your own rules skipped.
