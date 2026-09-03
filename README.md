# DriveSweep

DriveSweep is a free, open-source macOS menu-bar app that keeps external drives clean before you share or eject them. It is an alternative to commercial metadata cleaners such as BlueHarvest: there are no subscriptions, analytics, or network calls.

It deliberately touches only physical external, writable volumes. It ignores the startup disk, disk images, network shares, read-only volumes, and any volume whose name is listed in Preferences.

## At a glance

| Question | DriveSweep behavior |
| --- | --- |
| What is enabled initially? | AppleDouble `._*` and `.DS_Store` cleanup; automatic cleanup and advanced categories are off. |
| Can it clean every attached drive? | No. The drive must be a writable physical external volume, and excluded names, disk images, network shares, internal disks, and read-only media are rejected. |
| Is automatic cleanup safe by default? | It is disabled. Enabling it still requires a separate explicit allow rule for that exact VolumeUUID. |
| What should I do first? | Use **Analyze**. It is non-destructive and reports candidates, whitelist exclusions, and filesystem errors. |
| Can I undo a cleanup? | No. Treat cleanup as deletion; test first on a disposable drive and preserve needed AppleDouble extensions in the whitelist. |

## What it does

- Detects external drives at mount time and can clean an approved stable mount once, after a short delay.
- Opens a visible dashboard immediately, appears in the Dock, and keeps a broom menu-bar icon for quick actions and a non-destructive **Analyze** report for each drive.
- Shows the disk, current category, a redacted folder name, and completed categories while it works. It never invents a file-count or byte-count percentage it cannot know.
- Lets you cancel before the next filesystem item. If macOS is still opening a large folder, DriveSweep says so and waits rather than forcing the filesystem.
- Uses one physical filesystem traversal for the file-metadata preview instead of rescanning the same drive for each default category. Protected root metadata folders are counted separately, so an inaccessible `.TemporaryItems` folder does not make a normal analysis fail.
- Removes AppleDouble `._*` files while preserving extensions you add to the AppleDouble whitelist.
- Optionally removes `.DS_Store`, `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `.apdisk`, `.VolumeIcon.icns`, `Desktop.ini`, `Thumbs.db`, `.TemporaryItems`, and `.AppleDouble` directories.
- Lists each eligible drive with **Analyze**, **Clean now**, and **Clean and eject** actions, plus per-UUID exclusion and automatic-cleanup controls.
- Saves rules locally in macOS user defaults; no analytics, network calls, or subscriptions.

## Safety model

Automatic cleanup is **off by default**. It never runs merely because a drive is external: you must enable the global automatic-cleanup preference **and** explicitly allow automatic cleaning for that drive's stable VolumeUUID in its dashboard card. DriveSweep waits briefly after mount, rechecks the identity and consent, then cleans the approved mount once. When you finish copying, use **Clean and eject** for a final pass.

Analyze is always non-destructive: it reports candidates by category, AppleDouble files protected by the whitelist, and scan errors before you choose a cleanup action. Removing `._*` files may discard macOS-only metadata such as custom icons or legacy resource forks. The default **Cross-platform sharing** profile enables AppleDouble and `.DS_Store`; **Preserve Mac metadata** removes only `.DS_Store`; **Custom** preserves your individual toggles. All advanced categories require an explicit opt-in. Use the AppleDouble extension whitelist for types whose resource metadata must be preserved.

### Operation-time safeguards

- Dashboard and menu actions retain the selected drive URL **and** its VolumeUUID. A stale menu item cannot silently adopt a newly mounted drive with the same name.
- Cleanup rechecks the selected identity before each destructive category and stops later categories if the mount changed. **Clean and eject** rechecks it again immediately before ejecting.
- Traversals do not follow symlinks, do not cross into a different filesystem, skip application-package descendants, and reject unsafe root-level targets such as symlinks or mountpoints.
- Automatic cleanup checks the global setting and the UUID-specific consent again when queued work starts. Turning either one off prevents a queued automatic run from deleting files.
- The Dashboard and Preferences windows hide rather than being destroyed when closed, so they can safely be reopened from the Dock or menu bar.

These boundaries reduce the chance of acting on the wrong target; they do not make metadata deletion reversible. Keep backups and use **Analyze** before cleanup.

## Typical workflow

1. Connect the external drive and wait for it to appear in DriveSweep.
2. Choose **Analyze** and read the category counts. Nothing is deleted at this stage.
3. If AppleDouble metadata matters for a format, add its extension to the whitelist in **Preferences** and analyze again.
4. Choose **Clean now** only after confirming the report, or choose **Clean and eject** after the last file copy.
5. Keep automatic cleanup off unless you have tested the exact drive. If you enable it, allow it separately on that drive's dashboard card.

## Security and Apple verification

DriveSweep **is free**, but the `v0.4.4` public build is **not notarized by Apple**. That is why macOS can show “Apple could not verify that this app is free of malware” for a DMG downloaded from GitHub. This warning is about Apple's distribution verification process; it is not a report that DriveSweep is malware.

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

For `v0.4.4`, the published SHA-256 is:

```text
99bdb6ae7db5fed963506e15c2c4663e019d7fdf91f649096128b52038881cac
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

The repository test suite covers default settings, profile snapshots, whitelist preservation, cancellation, single-pass preview behavior, mount-identity changes between cleanup categories, disk-image rejection, safe window close/reopen lifecycles, bundle signing, and plist validity. It uses disposable temporary fixtures; it never cleans a real mounted volume.

## Manual end-to-end test

1. Use a disposable exFAT/FAT USB drive; do not test against a production backup.
2. Copy a few files to it from Finder, then open DriveSweep.
3. Select the drive and choose **Analizza**. Confirm the report and whitelist result before choosing **Pulisci ora** or **Pulisci ed espelli**.
4. To inspect the result before ejecting, run `find "/Volumes/DRIVE_NAME" -name '._*' -print`. It should print nothing after cleanup unless you intentionally whitelisted that file extension.
5. To test automatic cleaning, enable the global preference, press **Consenti auto** on that exact drive's dashboard card, then reconnect it. Confirm that no other drive is cleaned automatically.

## Troubleshooting

### macOS says the app cannot be verified

The public build is free and ad-hoc signed, not Apple-notarized. Verify the release checksum, then use Control-click → **Open** or remove quarantine from only `/Applications/DriveSweep.app` as described in [Installation](docs/INSTALLATION.md). Do not weaken Gatekeeper globally and do not bypass warnings for software from another source.

### My drive does not appear

DriveSweep intentionally refuses internal disks, disk images, network shares, read-only volumes, excluded names, and volumes that `diskutil` cannot identify as physical and external. Confirm the drive is writable and directly attached, then reconnect it. A permission or filesystem error appears in the Analyze report rather than being ignored.

### I changed my mind while it is running

Choose **Cancel**. DriveSweep stops before the next filesystem entry; macOS may take a moment to finish the folder it is already reading. It does not force-kill the filesystem operation.

## Maintainer release checklist

1. Run `make test`, the strict-warning build, AddressSanitizer harness, and `hdiutil verify build/DriveSweep.dmg`.
2. Verify the version matches `Resources/Info.plist`, `Casks/drivesweep.rb`, this README, Installation, and Security documentation.
3. Create a GitHub Release, attach the exact `build/DriveSweep.dmg`, and publish its SHA-256.
4. Install the released Cask on a test Mac and verify app launch, Dashboard reopen, and Preferences reopen without selecting a destructive action on user data.
5. State clearly whether the release is notarized. Do not claim Apple verification unless it has Developer ID signing, notarization, and a stapled ticket.

## License

Apache-2.0. See [LICENSE](LICENSE).
