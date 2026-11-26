cask "chipbar" do
  version "4.1.3"
  sha256 "c31f3a388022444058ed7f137f8ce448344ec2f9727104db2d41297983c60e22"

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
