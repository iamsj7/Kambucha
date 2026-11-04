# Setting up Mirror

This guide takes you from nothing to a first backup. It also covers external drives, Google Drive and OneDrive.

You need a Mac with Apple silicon, running macOS 26 or later.

## 1. Install

Mirror is built from source.

1. Install Xcode from the App Store, open it once, and accept the licence.
2. Get the project folder and open Terminal in it.
3. Fetch the bundled copy of rclone. This checks the download against a known checksum.

        scripts/fetch-rclone.sh

4. Build the app.

        scripts/build-app.sh

   The app is created at `dist/Mirror.app`. The script signs it with the identity named `Apple Development: Shaik Jaleel`. If you use a different identity, set `MIRROR_SIGN_IDENTITY` to its name first.

   Always sign with the same identity. macOS ties the Full Disk Access permission to the signature, so a different signature loses the permission.

5. Check the build.

        scripts/verify-bundle.sh

   It should finish with `OK`.

6. Drag `dist/Mirror.app` into `/Applications` and open it. A cloud icon appears in the menu bar. There is no Dock icon.

## 2. Allow Full Disk Access

Mirror cannot read some folders, such as `~/Documents`, until you allow this.

1. Open System Settings, then Privacy & Security, then Full Disk Access.
2. Click the plus button and choose `Mirror.app` from `/Applications`.
3. Switch it on. macOS may ask you to quit and reopen Mirror.

The background helper is inside the app, so this one permission covers both. Mirror checks it by having the helper, started by macOS, read a file that only Full Disk Access can open. Reading Documents and iCloud Drive is not enough, because macOS can allow those on their own.

Then allow it to run in the background. Open System Settings, then General, then Login Items & Extensions, and switch on Mirror under "Allow in the Background". Mirror's first-run screen walks through both steps.

If Full Disk Access is ever lost, Mirror sends a notification and shows "Needs Attention". Switch it back on in the same place.

## 3. Add a folder and run the first backup

The first-run screen ends with this step. Later sets start from the plus button in the toolbar.

1. Choose the folder you want to protect. It can hold many projects.
2. Mirror looks inside and switches on the presets for the kinds of project it finds, such as Node, Flutter or iOS.
3. The preview opens by itself. You see what will be backed up, what will be skipped and how large each part is, and a short list of items that need your decision. Untick anything you do not want, or tick anything you do. To change the presets, cancel and use the set's screen, then choose Preview Backup.
4. Choose Start Backup. Nothing is copied before this.

By default your destination is a folder called `Mac Backup` in iCloud Drive. Mirror only ever writes inside that folder. It will not start if a folder with that name exists but was not made by Mirror.

Some things Mirror will refuse or warn about:

- A folder inside iCloud Drive cannot be backed up, and two sets cannot overlap.
- A folder on a different disk from iCloud Drive works, but copies use real disk space.
- A name still used by a backup in the destination, left by a set you removed, is not taken over without asking. Choose a different name to start fresh, or Use Existing Backup to carry on from it. Anything in that backup that isn't in your folder moves to the archive.

The first backup of a large folder can take a long time. Google Drive allows about two files a second, so 120,000 files takes around 17 hours or more. Mirror stops cleanly after 25 minutes of cloud uploading and carries on at the next wake-up, so you can close the lid.

After that, Mirror runs about every 30 minutes and after you log in. If nothing changed, it does almost no work.

## 4. Reading each status

Status always shows words and a symbol, never colour alone.

| Status | What it means | What to do |
|---|---|---|
| Backed Up | Everything your rules include has been copied, checked and has reached the destination. The line under it shows the file count and the time. | Nothing. |
| Backing Up | A run is happening now. | Wait. |
| Uploading N files | The copy is made and the destination is still taking the files. For iCloud, macOS does the upload and may take a while. | Wait. It becomes Backed Up when done. |
| N deletions held | Files you removed on the Mac would have been removed from the backup too, and there were a lot of them. Mirror paused only the deletions. New and changed files still back up. | Choose Review Deletions. See "Undoing a mass deletion" in the [recovery guide](recovery.md). |
| Needs Attention | Something stopped a backup, such as a failed check, lost Full Disk Access, an expired sign-in or a missing destination marker. The line under it says why. | Read the reason and fix it. Mirror also sends one notification per problem. |
| Paused | You turned backups off. | Choose Resume when ready. |
| Not Set Up | No backup set yet. | Add one. |
| Not connected, last backed up N days ago | An external drive is not plugged in. This is not a failure, and it does not stop your other destinations reading Backed Up. | Plug it in when convenient. After 7 days Mirror gives one quiet reminder. |
| Not connected yet | An external drive has never finished a backup and is not plugged in. | Plug it in to start its first backup. |

"Backed Up" also shows a count of items to review. These are files your rules skip that you may want, such as a new `.env` file inside a build folder. They never block a backup.

## 5. Connect an external drive

Use this for an SSD or hard drive you plug in now and then.

### Choose the format first

| Format | Notes |
|---|---|
| APFS (best) or Mac OS Extended | Keeps symlinks and exact times. Use this if the drive is only for Macs. |
| exFAT | Works on Macs and Windows. It cannot hold symlinks, so Mirror saves each one as a small `.rclonelink` file. Times are only exact to 2 seconds. Mirror warns you when you choose it. Restoring still brings the symlinks back. See the [recovery guide](recovery.md). |

To format a drive, open Disk Utility, choose the drive, then Erase. This deletes everything on it. For protection with a password, choose "APFS (Encrypted)".

Mirror does not encrypt external drives. If you set a password on the drive, a locked drive does not appear on the Mac, and Mirror treats it as not connected. Mirror never tries to get around the lock.

### Add it

1. Plug the drive in.
2. In Mirror, choose Add Destination, then External Drive, and pick the drive from the list of connected drives.
3. Choose which sets use it.

Mirror remembers the drive by its internal ID and not its name. A different drive with the same name will never be written to.

### What to expect

- Mirror starts by itself when the drive is plugged in.
- Every time you connect it, Mirror compares the whole set, so a week away does not matter.
- The drive holds real copies, so it needs real space. Mirror checks that the changes will fit and stops with a clear message if they will not.
- If you unplug it in the middle of a run, nothing is marked complete and the next connection carries on.
- When it finishes, you get a notification saying it is safe to eject, with an Eject button.

## 6. Connect Google Drive

Mirror signs in to Google with your own Google client ID. A client ID is a free key that you make once in Google's console. You need it because the shared key used by rclone is being retired during 2026.

You will make one project, one consent screen and one Desktop client, then publish it. Publishing matters. If you leave the project in Testing mode, Google ends your sign-in every 7 days, and backups stop until you sign in again.

Google changes its console now and then. These steps follow Google's current "Google Auth Platform" pages and rclone's guide at <https://rclone.org/drive/>. If a name differs on your screen, look for the closest one.

### 6.1 Create a project and turn on the Drive API

1. Go to <https://console.cloud.google.com/> and sign in with the Google account that will hold the backup.
2. Use the project picker at the top to create a New Project. Name it "Mirror".
3. Open APIs & Services, then Library. Search for "Google Drive API" and choose Enable.

### 6.2 Set up the consent screen

1. Open <https://console.cloud.google.com/auth/overview> (Google Auth Platform) and choose Get started.
2. App information: App name "Mirror", and your email as the support email. Choose Next.
3. Audience: choose External. Choose Next.
4. Contact information: enter your email. Choose Next, agree to the policy and choose Create.
5. Open Data Access, choose Add or remove scopes, and add the Google Drive API scope ending in `/auth/drive.file`. Save. This is the narrow scope: Mirror can see only the files it creates itself.
6. Open Audience, choose Add users under Test users, and add your own Google address. Save. You need this for the first sign-in even though you will publish next.

### 6.3 Create the Desktop client

1. Open Clients (or Overview, then Create OAuth client).
2. Application type: Desktop app. Name it "Mirror". Choose Create.
3. Copy the Client ID and the Client secret. The secret is shown once, so save it now, in a password manager. Anyone with both can ask Google to act as your app, so do not put them in a document that others can read.

### 6.4 Publish to production

1. Open Audience. Under Publishing status, choose Publish app, then Confirm. The status changes from Testing to In production.
2. If the button is greyed out, open Branding, enter a home page link and a privacy policy link (any pages you control will do for a personal app), save, and try again.

Google says that in Testing, sign-ins last 7 days. In production they do not expire on that clock. You do not need to go through Google's verification. This is your own app, used by you.

When you sign in you may see "Google hasn't verified this app". That is expected for your own app. Choose Advanced, then continue to Mirror.

### 6.5 Connect in Mirror

1. Choose Add Destination, then Google Drive.
2. Paste the Client ID and Client secret.
3. Choose Sign In. A browser opens. Use the same Google account. Allow access to files that Mirror creates.
4. Leave encryption on. It cannot be changed later without making a new destination.
5. Mirror shows your Recovery Kit. Save it or print it, somewhere that is not on this Mac and not inside a folder that Mirror backs up (Mirror refuses to save it there). Backups to this destination do not start until you confirm that you saved it.

The Recovery Kit holds your passphrase, your salt and your Google client ID and secret. Without it, nobody can open the backup. With it, anyone can. Keep it like a house key.

Some time after the first backup, Mirror asks you to paste the Recovery Kit as a test. It uses only what is in the Kit to download and decrypt one small file. It asks again every 6 months, with one notification, and the reminder blocks nothing. Do it. It is the only way to know the Kit works. If the Kit does not open the backup, Mirror alerts you at once and shows "Needs Attention" until a test passes.

If Google ever shows "Sign-in expired", choose Reconnect on that destination. Only that destination pauses.

## 7. Connect OneDrive

1. Choose Add Destination, then OneDrive.
2. Choose Sign In. A browser opens. Sign in with the Microsoft account that will hold the backup, and allow access.
3. Leave encryption on, and save the Recovery Kit as described in 6.5.

Things to know, from rclone's guide at <https://rclone.org/onedrive/>:

- Sign-in expires if the destination is unused for 90 days. Mirror's weekly check keeps it alive. If it does expire, choose Reconnect.
- Some work and school accounts block rclone. The error mentions `AADSTS65005`. Only your organisation's administrator can fix that. Use a personal account instead.
- If your account asks for a second step (MFA) after you turn it on, choose Reconnect.
- OneDrive limits paths to 400 characters. Encrypted names are longer, so Mirror uses a compact encoding. Very deep folders could still be too long, and Mirror will list them for you.

## 8. Settings worth knowing

- **Schedule:** every 30 minutes by default.
- **Archive:** old versions and deleted files are kept 30 days by default.
- **Deletion limit:** deletions are held if a run would remove at least 100 files and more than 5% of the set, or more than 2,000 files at any size. Files inside `.git` do not count.
- **Secrets and Git history:** both are backed up by default, per set. Turning off Secrets means `.env` files and keys are not backed up.

## 9. If something goes wrong

Open the Activity view for the log of each run. Raw logs are in `~/Library/Logs/Mirror/`, kept 30 days. They list file paths and counts, never file contents.

To get files back, see the [recovery guide](recovery.md).
