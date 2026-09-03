cask "drivesweep" do
  version "0.4.0"
  sha256 "8c64ec959bd27103393a6ae50449a5b649c53aed654de0eb4c2fa9114c925937"

  url "https://github.com/naicud/drivesweep/releases/download/v#{version}/DriveSweep.dmg"
  name "DriveSweep"
  desc "Clean macOS metadata from external drives"
  homepage "https://github.com/naicud/drivesweep"

  depends_on macos: :ventura

  app "DriveSweep.app"

  caveats <<~EOS
    DriveSweep is free and open source, but this release is not Apple-notarized.
    Current Homebrew versions have no --no-quarantine install option. After
    reviewing this project, remove the quarantine flag only from this app copy:
      xattr -d com.apple.quarantine /Applications/DriveSweep.app
    Review https://github.com/naicud/drivesweep/blob/main/docs/SECURITY.md
    before bypassing quarantine for any downloaded app.
  EOS
end
