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
    DriveSweep is ad-hoc signed but not notarized for this first release.
    If macOS blocks its first launch, Control-click the app in Applications,
    choose Open, then confirm Open.
  EOS
end
