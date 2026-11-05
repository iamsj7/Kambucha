# Security

Kambucha handles your files, cloud sign-ins and encryption passwords, so security reports are very welcome.

## Reporting a problem

Please don't open a public issue. Use [GitHub's private reporting](https://github.com/iamsj7/Kambucha/security/advisories/new) and include what you found, how to reproduce it, and which version or commit you used.

## How secrets are handled

- Passwords and sign-in tokens are stored only in your login Keychain, and never in logs, run records or command-line arguments.
- During a Google Drive or OneDrive backup they're handed to rclone: tokens through a private temporary file that's removed afterwards, and encryption keys through rclone's environment.
- Google Drive and OneDrive backups are encrypted on your Mac before upload, using rclone's crypt. Your Recovery Kit is the only other way to open them, so keep it safe.
- iCloud Drive and external drive backups aren't encrypted by Kambucha. They rely on iCloud's protection, or on your drive's own password.
- rclone is pinned to one version and checked against a known checksum.

## What Kambucha doesn't protect against

Kambucha guards against mistakes, lost Macs and cloud providers reading your files. It doesn't protect you from malware already running under your account:

- A program running as you can read your files, and it can read the encryption keys while a cloud backup runs.
- The background helper checks that its caller is signed by the same team as the app. That check is one layer of defence, and a program running as you can get past it.
- Touch ID or your password guards showing a Recovery Kit inside the app, but that doesn't stop the case above.
- The archive keeps deleted files for 30 days by default, which helps you recover from damage, but it isn't a separate, tamper-proof copy.
