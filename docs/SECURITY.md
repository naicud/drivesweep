# Security and distribution status

## Current release status

DriveSweep `v0.2.0` is free, open source under Apache-2.0, and ad-hoc signed for bundle integrity. It is **not Developer ID signed or Apple-notarized**. macOS therefore may display a downloaded-app warning when you open the DMG build normally.

Apple notarization is a paid distribution service because it requires membership in the Apple Developer Program and a Developer ID certificate. There is no free setting that makes macOS show a third-party downloadable app as Apple-verified for every user.

For a free local installation, use either:

- Homebrew followed by `xattr -d com.apple.quarantine /Applications/DriveSweep.app`; or
- a trusted DMG with its SHA-256 checked, followed by Control-click → **Open** or removal of quarantine from `/Applications/DriveSweep.app`; or
- a local build from this repository.

These choices change local launch handling only. They do not mean that Apple has scanned, notarized, or approved the app.

## Verify a release

The `v0.2.0` DMG SHA-256 is:

```text
28f6bc913c8290b3ba2ae19333ed560082bb00e246cdbeac83bdb920fa856065
```

Calculate it after downloading:

```sh
shasum -a 256 DriveSweep.dmg
```

Compare the entire output with the value above and download only from the official [GitHub releases page](https://github.com/naicud/drivesweep/releases).

## What the app accesses

DriveSweep runs locally. It has no telemetry, account system, subscription, or networking code. It asks macOS's `diskutil` which mounted volumes are physical and external, then performs configured file-removal operations only inside eligible external writable volumes.

It does not touch the startup disk, disk images, network shares, read-only volumes, or a drive explicitly excluded in Preferences. Automatic cleanup is off by default; when enabled it waits briefly and cleans a stable eligible mount once. DriveSweep does not descend into a distinct nested filesystem mount. For a final pass, choose **Clean and eject** after copying is complete.

## Data effects

Removing `._*` files can discard macOS-only metadata such as custom icons and legacy resource forks. Add extensions to the AppleDouble whitelist when that metadata must be retained. DriveSweep enables only `.DS_Store` cleanup by default; AppleDouble, `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `.apdisk`, `.VolumeIcon.icns`, `Desktop.ini`, `Thumbs.db`, `.TemporaryItems`, and `.AppleDouble` directories are opt-in. Test first on a disposable USB drive and exclude any volume where that metadata matters.

## For maintainers

Do not describe a release as “Apple verified,” “notarized,” or “malware-free” unless it has actually been Developer ID signed, notarized by Apple, and stapled. If that paid distribution path is added in the future, document the certificate identity, hardened-runtime configuration, notarization submission, and stapling step in the release process.
