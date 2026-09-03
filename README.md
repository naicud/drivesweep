# DriveSweep

DriveSweep is a free, open-source macOS menu-bar app that keeps external drives clean before you share or eject them. It is an alternative to commercial metadata cleaners such as BlueHarvest: there are no subscriptions, analytics, or network calls.

It deliberately touches only physical external, writable volumes. It ignores the startup disk, disk images, network shares, read-only volumes, and any volume whose name is listed in Preferences.

## What it does

- Detects external drives at mount time and can clean an approved stable mount once, after a short delay.
- Opens a visible dashboard immediately, appears in the Dock, and keeps a broom menu-bar icon for quick actions and a non-destructive **Analyze** report for each drive.
- Shows the disk, current category, a redacted folder name, and completed categories while it works. It never invents a file-count or byte-count percentage it cannot know.
- Lets you cancel before the next filesystem item. If macOS is still opening a large folder, DriveSweep says so and waits rather than forcing the filesystem.
- Uses one physical filesystem traversal for the file-metadata preview instead of rescanning the same drive for each default category.
- Removes AppleDouble `._*` files while preserving extensions you add to the AppleDouble whitelist.
- Optionally removes `.DS_Store`, `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `.apdisk`, `.VolumeIcon.icns`, `Desktop.ini`, `Thumbs.db`, `.TemporaryItems`, and `.AppleDouble` directories.
- Lists each eligible drive with **Analyze**, **Clean now**, and **Clean and eject** actions, plus per-UUID exclusion and automatic-cleanup controls.
- Saves rules locally in macOS user defaults; no analytics, network calls, or subscriptions.

## Safety model

Automatic cleanup is **off by default**. It never runs merely because a drive is external: you must enable the global automatic-cleanup preference **and** explicitly allow automatic cleaning for that drive's stable VolumeUUID in its dashboard card. DriveSweep waits briefly after mount, rechecks the identity and consent, then cleans the approved mount once. When you finish copying, use **Clean and eject** for a final pass.

Analyze is always non-destructive: it reports candidates by category, AppleDouble files protected by the whitelist, and scan errors before you choose a cleanup action. Removing `._*` files may discard macOS-only metadata such as custom icons or legacy resource forks. The default **Cross-platform sharing** profile enables AppleDouble and `.DS_Store`; **Preserve Mac metadata** removes only `.DS_Store`; **Custom** preserves your individual toggles. All advanced categories require an explicit opt-in. Use the AppleDouble extension whitelist for types whose resource metadata must be preserved.

## Security and Apple verification

DriveSweep **is free**, but the `v0.4.0` public build is **not notarized by Apple**. That is why macOS can show “Apple could not verify that this app is free of malware” for a DMG downloaded from GitHub. This warning is about Apple's distribution verification process; it is not a report that DriveSweep is malware.

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
xattr -d com.apple.quarantine /Applications/DriveSweep.app
```

This does **not** make DriveSweep Apple-notarized or certify it as safe. See the full [Homebrew instructions](docs/INSTALLATION.md#homebrew) and [security notes](docs/SECURITY.md).

### DMG

Download `DriveSweep.dmg` from the [GitHub Releases page](https://github.com/naicud/drivesweep/releases), open it, and move the app to Applications.

For `v0.4.0`, the published SHA-256 is:

```text
8c64ec959bd27103393a6ae50449a5b649c53aed654de0eb4c2fa9114c925937
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
3. Select the drive and choose **Analizza**. Confirm the report and whitelist result before choosing **Pulisci ora** or **Pulisci ed espelli**.
4. To inspect the result before ejecting, run `find "/Volumes/DRIVE_NAME" -name '._*' -print`. It should print nothing after cleanup unless you intentionally whitelisted that file extension.
5. To test automatic cleaning, enable the global preference, press **Consenti auto** on that exact drive's dashboard card, then reconnect it. Confirm that no other drive is cleaned automatically.

## GitHub release checklist

1. Build and test on a Mac with an external test volume.
2. Create a GitHub Release, attach `build/DriveSweep.dmg`, and publish its SHA-256.
3. State clearly whether the release is notarized. Do not claim Apple verification unless it has Developer ID signing, notarization, and a stapled ticket.
4. Developer ID signing and notarization are optional paid Apple Developer Program features; they are not required to build, inspect, or run DriveSweep locally.

## License

Apache-2.0. See [LICENSE](LICENSE).
