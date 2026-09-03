# Installation

DriveSweep is free and open source. The public `v0.4.2` app is ad-hoc signed, not Apple-notarized. The methods below let you run it locally without an Apple Developer subscription.

Only trust a release downloaded from [the official DriveSweep GitHub releases page](https://github.com/naicud/drivesweep/releases), or build the public source yourself.

## Homebrew

```sh
brew tap naicud/drivesweep https://github.com/naicud/drivesweep
brew install --cask naicud/drivesweep/drivesweep
xattr -d com.apple.quarantine /Applications/DriveSweep.app
open -a DriveSweep
```

Current Homebrew versions do not offer a `--no-quarantine` option. The `xattr` command above removes macOS's download-quarantine attribute from only this installed application. It allows this local copy to open without the downloaded-app warning; it does not notarize the application or prove it is safe. Read the source and release information before choosing to use it.

To update later, use:

```sh
brew upgrade --cask naicud/drivesweep/drivesweep
    xattr -d com.apple.quarantine /Applications/DriveSweep.app
```

To remove it:

```sh
brew uninstall --cask drivesweep
```

## DMG

1. Download `DriveSweep.dmg` from the official [releases page](https://github.com/naicud/drivesweep/releases).
2. Verify the download before opening it. For `v0.4.2`:

   ```sh
   shasum -a 256 ~/Downloads/DriveSweep.dmg
   ```

   The expected digest is `9eb50a4eb7beb7f627fc0e89223c1bac60f5d7def199140b23e9ec1304311a90`.
3. Open the DMG and drag `DriveSweep.app` to `/Applications`.
4. Use either one of these local launch choices:

   - Control-click `DriveSweep.app` in Finder, choose **Open**, then choose **Open** again; or
   - in Terminal, remove quarantine from only this app copy:

     ```sh
xattr -d com.apple.quarantine /Applications/DriveSweep.app
     open -a DriveSweep
     ```

Do not use either approach for software from an unknown source. Removing quarantine is local and reversible in practice by deleting the app and downloading it again; it does not disable Gatekeeper system-wide.

## From source

Building locally is the most inspectable option.

```sh
git clone https://github.com/naicud/drivesweep.git
cd drivesweep
make build
make test
open build/DriveSweep.app
```

The build uses the macOS SDK and needs Xcode Command Line Tools. Install them if necessary:

```sh
xcode-select --install
```

## First use

When DriveSweep opens, its dashboard appears immediately and a broom icon stays in the menu bar. Automatic cleanup is off by default. Even after enabling it in Preferences, DriveSweep cleans only a stable mount whose VolumeUUID you explicitly approved with **Consenti auto** in that drive's dashboard card; it waits briefly and rechecks the identity before cleaning once. `.DS_Store` and AppleDouble (`._*`) cleanup are enabled by default; every other metadata category is opt-in. Use **Analizza** before cleanup and **Clean and eject** only after file copying finishes, for a final cleanup pass.

Use a disposable test USB drive first. DriveSweep deliberately ignores internal disks, disk images, network shares, read-only media, and names you exclude in Preferences.
