cask "chipbar" do
  version "1.1.3"
  sha256 "2056cd84aae5877d386cac55d3f8dbfba3a5f68634b275cfe76f621fca83050c"

  url "https://github.com/wwwwzzzzkkkk/ChipBar/releases/download/v#{version}/ChipBar-macOS-arm64.zip"
  name "ChipBar"
  desc "Native menu bar client for macmon power and temperature monitoring"
  homepage "https://github.com/wwwwzzzzkkkk/ChipBar"

  depends_on arch: :arm64
  depends_on macos: :ventura
  depends_on formula: "macmon"

  app "ChipBar.app"

  uninstall quit: "local.chipbar.monitor"

  caveats <<~EOS
    ChipBar is locally signed and not notarized. If macOS blocks opening it,
    allow ChipBar in System Settings > Privacy & Security.
    Sensor availability depends on the installed macmon and your hardware.
  EOS
end
