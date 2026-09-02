# DriveSweep

DriveSweep is a free, open-source macOS menu-bar app that keeps external drives clean before you share or eject them. It is an alternative to commercial metadata cleaners such as BlueHarvest: there are no subscriptions, analytics, or network calls.

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

## Security and Apple verification

DriveSweep **is free**, but the `v0.1.0` public build is **not notarized by Apple**. That is why macOS can show “Apple could not verify that this app is free of malware” for a DMG downloaded from GitHub. This warning is about Apple's distribution verification process; it is not a report that DriveSweep is malware.

You can use it without paying for an Apple Developer membership. Choose one of the local-install methods in [Installation](docs/INSTALLATION.md), review the source, and verify the published SHA-256 before trusting a release. Details, limitations, and the precise role of quarantine are in [Security](docs/SECURITY.md).

## Requirements

- macOS 13 Ventura or later
- Xcode Command Line Tools

Every push and pull request is compiled by the included GitHub Actions workflow. The workflow uploads a ready-to-test `DriveSweep.dmg` artifact.

## Install

### Homebrew

```sh
brew tap naicud/drivesweep https://github.com/naicud/drivesweep
brew install --cask naicud/drivesweep/drivesweep
```

Current Homebrew versions do not provide a `--no-quarantine` install flag. After reviewing the project and installing it, remove the download-quarantine flag from this specific local app copy:

```sh
xattr -dr com.apple.quarantine /Applications/DriveSweep.app
```

This does **not** make DriveSweep Apple-notarized or certify it as safe. See the full [Homebrew instructions](docs/INSTALLATION.md#homebrew) and [security notes](docs/SECURITY.md).

### DMG

Download `DriveSweep.dmg` from the [GitHub Releases page](https://github.com/naicud/drivesweep/releases), open it, and move the app to Applications.

For `v0.1.0`, the published SHA-256 is:

```text
463d1811316342b88264e3346c0fd2b2585c48328a9e25c7480c55c0bef69465
```

After copying the application, use the one-time Control-click → **Open** route or remove quarantine as documented in [Installation](docs/INSTALLATION.md#dmg). Do not bypass the warning for a DMG you did not download from the official [DriveSweep releases](https://github.com/naicud/drivesweep/releases) page.

### Install from source

```sh
git clone https://github.com/naicud/drivesweep.git
cd drivesweep
make build
open build/DriveSweep.app
```

This is the most transparent route: you compile the public source on your own Mac. See [Installation](docs/INSTALLATION.md#from-source) for verification and cleanup notes.

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

1. Build and test on a Mac with an external test volume.
2. Create a GitHub Release, attach `build/DriveSweep.dmg`, and publish its SHA-256.
3. State clearly whether the release is notarized. Do not claim Apple verification unless it has Developer ID signing, notarization, and a stapled ticket.
4. Developer ID signing and notarization are optional paid Apple Developer Program features; they are not required to build, inspect, or run DriveSweep locally.

## License

Apache-2.0. See [LICENSE](LICENSE).
