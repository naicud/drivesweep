# DriveSweep

DriveSweep is a lightweight macOS menu-bar app that keeps external drives clean before you share or eject them. It is a free, open-source alternative to commercial metadata cleaners.

It deliberately touches only physical external, writable volumes. It ignores the startup disk, disk images, network shares, read-only volumes, and any volume whose name is listed in Preferences.

## What it does

- Detects external drives at mount time and can clean them automatically.
- Removes AppleDouble `._*` files through macOS' `dot_clean` utility.
- Optionally removes `.DS_Store`, `.Trashes`, `.Spotlight-V100`, and `.fseventsd`.
- Lists each eligible drive in the menu bar with **Clean now** and **Clean and eject** actions.
- Saves rules locally in macOS user defaults; no analytics, network calls, or subscriptions.

## Safety model

Automatic cleanup happens once per mount. This avoids racing with a file copy that is still running. When you finish copying, use **Clean and eject** from the DriveSweep menu for a final pass.

Removing `._*` files may discard macOS-only metadata such as custom icons or legacy resource forks. The default settings focus on files that commonly break car stereos, cameras, consoles, TVs, Windows, and Linux devices. Spotlight and file-event cleanup are opt-in because macOS may recreate them.

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools

Every push and pull request is compiled by the included GitHub Actions workflow. The workflow uploads a ready-to-test `DriveSweep.dmg` artifact.

## Install

### Homebrew

```sh
brew tap naicud/disk-cleaner-macos https://github.com/naicud/disk-cleaner-macos
brew install --cask naicud/disk-cleaner-macos/drivesweep
```

The first public release is ad-hoc signed but not notarized. If macOS blocks its first launch, Control-click **DriveSweep.app** in Applications, choose **Open**, then confirm **Open**.

### DMG

Download `DriveSweep.dmg` from the [GitHub Releases page](https://github.com/naicud/disk-cleaner-macos/releases), open it, and move the app to Applications.

## Build and run

```sh
make build
open build/DriveSweep.app
```

Run the build checks with:

```sh
make test
```

To create a disk image:

```sh
make dmg
```

If you build from an exFAT/FAT external disk, macOS can create `._*` AppleDouble files beside source and build files. The build removes them from the app bundle before signing. For a Git checkout already affected by such files, run `dot_clean -m .` from the repository root before using Git.

## Manual end-to-end test

1. Use a disposable exFAT/FAT USB drive; do not test against a production backup.
2. Copy a few files to it from Finder, then open DriveSweep.
3. Select the drive in the menu bar and choose **Pulisci ora** or **Pulisci ed espelli**.
4. To inspect the result before ejecting, run `find "/Volumes/DRIVE_NAME" -name '._*' -print`. It should print nothing after cleanup.
5. Reconnect the drive and confirm that the app detects it and cleans it automatically when that preference is enabled.

## GitHub release checklist

1. Change `CFBundleIdentifier` in `Resources/Info.plist` to your own reverse-DNS identifier.
2. Build and test on a Mac with an external test volume.
3. Sign and notarize release builds with your Apple Developer certificate before distributing broadly.
4. Create a GitHub Release and attach `build/DriveSweep.dmg`.

## License

Apache-2.0. See [LICENSE](LICENSE).
