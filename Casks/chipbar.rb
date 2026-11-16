cask "chipbar" do
  version "4.0.2"
  sha256 "37971f03279ec682b317715beef90de9d71de272d467675d5319ea6d3d31256a"

  url "https://github.com/wwwwzzzzkkkk/ChipBar/releases/download/chipbar-v#{version}/ChipBar-macOS-arm64.zip"
  name "ChipBar"
  desc "Native Apple Silicon performance monitor with read-only Mac cluster"
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
