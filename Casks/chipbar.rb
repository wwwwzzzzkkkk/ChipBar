cask "chipbar" do
  version "1.0.2"
  sha256 "6b474ab95025825ad48383d988be00534a6ac54cfeb05b3d133301c8d377eda5"

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
