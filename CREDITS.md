# Credits

Kambucha is written by Shaik Jaleel and released under the [MIT License](LICENSE).

## rclone

Kambucha does its copying through [rclone](https://rclone.org), by Nick Craig-Wood and the rclone contributors. rclone is released under the MIT License.

This repository doesn't contain rclone. `scripts/fetch-rclone.sh` downloads a pinned release, checks it against a known checksum, and the build places it inside the app at `Contents/Helpers/rclone`. Its licence text ships in the app at `Contents/Resources/ThirdPartyLicenses/rclone.txt`, and you can open it from Settings.

The rclone program includes open source Go libraries under their own licences. See the [rclone repository](https://github.com/rclone/rclone) for them.

## Apple

Kambucha is built with Apple's frameworks, and has no other third-party code. Its symbols are SF Symbols, which are Apple's and are covered by Apple's terms. Apple, Mac, macOS and iCloud are trademarks of Apple Inc.

Google Drive is a trademark of Google LLC, and OneDrive is a trademark of Microsoft Corporation. Kambucha isn't affiliated with or endorsed by any of them.
