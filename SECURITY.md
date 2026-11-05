# Security

Kambucha handles your files, cloud sign-ins and encryption passwords, so security reports are very welcome.

## Reporting a problem

Please don't open a public issue. Use [GitHub's private reporting](https://github.com/iamsj7/Kambucha/security/advisories/new) and include what you found, how to reproduce it, and which version or commit you used.

## How secrets are handled

- Passwords and sign-in tokens are kept only in your login Keychain. They're never written to logs, run records or command-line arguments.
- Google Drive and OneDrive backups are encrypted on your Mac before upload, using rclone's crypt. Your Recovery Kit is the only other way to open them, so keep it safe.
- iCloud Drive and external drive backups aren't encrypted by Kambucha. They rely on iCloud's protection, or on your drive's own password.
- Only code signed by the same team as the app can use the background helper. A build that can't prove its own signature refuses every request.
- rclone is pinned to one version and checked against a known checksum.
