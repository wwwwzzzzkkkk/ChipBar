cask "chipbar" do
  version "1.0.7"
  sha256 "0062e8d38da5532b07a3f6f20727731d9fe221145d4b3832ce245a9de30bbaba"

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
