# Installation

DriveSweep is free and open source. The public `v0.1.0` app is ad-hoc signed, not Apple-notarized. The methods below let you run it locally without an Apple Developer subscription.

Only trust a release downloaded from [the official DriveSweep GitHub releases page](https://github.com/naicud/drivesweep/releases), or build the public source yourself.

## Homebrew

```sh
brew tap naicud/drivesweep https://github.com/naicud/drivesweep
brew install --cask --no-quarantine naicud/drivesweep/drivesweep
open -a DriveSweep
```

`--no-quarantine` tells Homebrew not to apply macOS's download-quarantine extended attribute to this installation. It prevents the normal downloaded-app Gatekeeper dialog for this local copy. It does not notarize the application or prove it is safe: read the source and release information before choosing to use it.

To update later, use the same option:

```sh
brew upgrade --cask --no-quarantine naicud/drivesweep/drivesweep
```

To remove it:

```sh
brew uninstall --cask drivesweep
```

## DMG

1. Download `DriveSweep.dmg` from the official [releases page](https://github.com/naicud/drivesweep/releases).
2. Verify the download before opening it. For `v0.1.0`:

   ```sh
   shasum -a 256 ~/Downloads/DriveSweep.dmg
   ```

   The expected digest is `463d1811316342b88264e3346c0fd2b2585c48328a9e25c7480c55c0bef69465`.
3. Open the DMG and drag `DriveSweep.app` to `/Applications`.
4. Use either one of these local launch choices:

   - Control-click `DriveSweep.app` in Finder, choose **Open**, then choose **Open** again; or
   - in Terminal, remove quarantine from only this app copy:

     ```sh
     xattr -dr com.apple.quarantine /Applications/DriveSweep.app
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

When DriveSweep opens, it appears as a broom icon in the menu bar. It automatically cleans an eligible drive once when that drive mounts, if the preference is enabled. Use **Clean and eject** only after file copying finishes, for a final cleanup pass.

Use a disposable test USB drive first. DriveSweep deliberately ignores internal disks, disk images, network shares, read-only media, and names you exclude in Preferences.
