cask "drivesweep" do
  version "0.1.0"
  sha256 "463d1811316342b88264e3346c0fd2b2585c48328a9e25c7480c55c0bef69465"

  url "https://github.com/naicud/drivesweep/releases/download/v#{version}/DriveSweep.dmg"
  name "DriveSweep"
  desc "Clean macOS metadata from external drives"
  homepage "https://github.com/naicud/drivesweep"

  depends_on macos: ">= :ventura"

  app "DriveSweep.app"

  caveats <<~EOS
    DriveSweep is free and open source, but this release is not Apple-notarized.
    --no-quarantine avoids the downloaded-app warning for this local install;
    it does not make an Apple verification claim. Alternatively, remove the
    quarantine flag only from this app copy:
      xattr -dr com.apple.quarantine /Applications/DriveSweep.app
    Review https://github.com/naicud/drivesweep/blob/main/docs/SECURITY.md
    before bypassing quarantine for any downloaded app.
  EOS
end
