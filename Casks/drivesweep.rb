cask "drivesweep" do
  version "0.4.9"
  sha256 "3a04405a16e143b18934151ede2f119b4de031078f9a643a75c2ffd29dcfdd1f"

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
