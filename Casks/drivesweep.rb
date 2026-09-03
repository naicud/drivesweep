cask "drivesweep" do
  version "0.4.2"
  sha256 "9eb50a4eb7beb7f627fc0e89223c1bac60f5d7def199140b23e9ec1304311a90"

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
