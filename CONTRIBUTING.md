# Contributing

Bug reports and pull requests are welcome.

## Before you start

- For a change larger than a small fix, please open an issue first.
- Kambucha uses Apple frameworks only. Please don't add third-party packages.
- It supports Apple silicon and macOS 26 or later only.
- Follow Apple's [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/), and use native controls.

## Build and test

1. Follow "Build from source" in the [README](README.md).
2. Run the tests:

        swift test

The tests use their own temporary folders and never touch your real files. One test suite mounts a small disk image, and the secret store tests write throwaway items to your login Keychain and remove them. A test run that gets killed can leave one behind, with `kambucha.test` in its name. Two tests that involve rclone sometimes fail under load: `anExpiredSignInIsToldApartFromAFailedRead` and `kitProofAgainstRealRclone`. They're being worked on, so run those again before treating a failure as yours.

## Pull requests

- Add a test for what you change.
- Keep the build free of warnings.
- Changes to backup, restore, deletion, verification or signature checks need extra care. Say in the pull request how you tested them.
- By contributing, you agree your work is released under the [MIT License](LICENSE).
