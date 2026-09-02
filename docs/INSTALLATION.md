# Installation

DriveSweep is free and open source. The public `v0.2.0` app is ad-hoc signed, not Apple-notarized. The methods below let you run it locally without an Apple Developer subscription.

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
2. Verify the download before opening it. For `v0.2.0`:

   ```sh
   shasum -a 256 ~/Downloads/DriveSweep.dmg
   ```

   The expected digest is `28f6bc913c8290b3ba2ae19333ed560082bb00e246cdbeac83bdb920fa856065`.
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

When DriveSweep opens, its dashboard appears immediately and a broom icon stays in the menu bar. Automatic cleanup is off by default. If you enable it in Preferences, DriveSweep waits briefly after mount and cleans each stable eligible mount once. `.DS_Store` cleanup is enabled by default; AppleDouble and every additional metadata category are opt-in. Use **Clean and eject** only after file copying finishes, for a final cleanup pass.

Use a disposable test USB drive first. DriveSweep deliberately ignores internal disks, disk images, network shares, read-only media, and names you exclude in Preferences.
