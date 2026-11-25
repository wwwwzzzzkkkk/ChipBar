cask "chipbar" do
  version "4.0.24"
  sha256 "115d23dfd14afb97af315d1fe695b217c0adb0b3442d530469c79053b80fc577"

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
