# Security and distribution status

## Current release status

DriveSweep `v0.3.0` is free, open source under Apache-2.0, and ad-hoc signed for bundle integrity. It is **not Developer ID signed or Apple-notarized**. macOS therefore may display a downloaded-app warning when you open the DMG build normally.

Apple notarization is a paid distribution service because it requires membership in the Apple Developer Program and a Developer ID certificate. There is no free setting that makes macOS show a third-party downloadable app as Apple-verified for every user.

For a free local installation, use either:

- Homebrew followed by `xattr -d com.apple.quarantine /Applications/DriveSweep.app`; or
- a trusted DMG with its SHA-256 checked, followed by Control-click → **Open** or removal of quarantine from `/Applications/DriveSweep.app`; or
- a local build from this repository.

These choices change local launch handling only. They do not mean that Apple has scanned, notarized, or approved the app.

## Verify a release

The `v0.3.0` DMG SHA-256 is:

```text
8be13050a741e8cb58506bfc7bf292905ae7c261a8ed1607aa8a804e6e3f87be
```

Calculate it after downloading:

```sh
shasum -a 256 DriveSweep.dmg
```

Compare the entire output with the value above and download only from the official [GitHub releases page](https://github.com/naicud/drivesweep/releases).

## What the app accesses

DriveSweep runs locally. It has no telemetry, account system, subscription, or networking code. It asks macOS's `diskutil` which mounted volumes are physical and external, then performs configured file-removal operations only inside eligible external writable volumes.

It does not touch the startup disk, disk images, network shares, read-only volumes, or a drive explicitly excluded in Preferences. Automatic cleanup is off by default and is a two-part consent: the global automatic setting must be enabled and the exact stable VolumeUUID must have an explicit automatic-cleanup rule. It waits briefly, rechecks the mount identity and that UUID rule, and then cleans an approved mount once. DriveSweep does not descend into a distinct nested filesystem mount. For a final pass, choose **Clean and eject** after copying is complete.

## Data effects

Analyze is non-destructive and reports category counts, whitelist-protected AppleDouble files, and scan errors. Removing `._*` files can discard macOS-only metadata such as custom icons and legacy resource forks. Add extensions to the AppleDouble whitelist when that metadata must be retained. The default Cross-platform sharing profile enables AppleDouble and `.DS_Store`; the Preserve Mac metadata profile removes only `.DS_Store`; custom mode retains individual choices. `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `.apdisk`, `.VolumeIcon.icns`, `Desktop.ini`, `Thumbs.db`, `.TemporaryItems`, and `.AppleDouble` directories are opt-in. Test first on a disposable USB drive and exclude any volume where that metadata matters.

## For maintainers

Do not describe a release as “Apple verified,” “notarized,” or “malware-free” unless it has actually been Developer ID signed, notarized by Apple, and stapled. If that paid distribution path is added in the future, document the certificate identity, hardened-runtime configuration, notarization submission, and stapling step in the release process.
