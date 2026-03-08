cask "openclaw-activity-bar" do
  version "0.1.0"
  sha256 :no_check

  url "https://github.com/avchaykin/openclaw-remote-activity/archive/refs/tags/v#{version}.tar.gz"
  name "OpenClaw Activity Bar"
  desc "macOS menu bar client for OpenClaw activity status"
  homepage "https://github.com/avchaykin/openclaw-remote-activity"

  depends_on macos: ">= :sonoma"

  # Build from source during cask install (no notarized app artifact yet)
  stage_only true

  installer script: {
    executable: "/bin/bash",
    args: [
      "-lc",
      <<~EOS
        set -euo pipefail
        cd "openclaw-remote-activity-#{version}/client"
        swift build -c release --disable-sandbox
        mkdir -p /Applications/OpenClawActivity.app/Contents/MacOS
        cat > /Applications/OpenClawActivity.app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.openclaw.activity</string>
  <key>CFBundleName</key><string>OpenClawActivity</string>
  <key>CFBundleExecutable</key><string>OpenClawActivity</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleVersion</key><string>#{version}</string>
  <key>CFBundleShortVersionString</key><string>#{version}</string>
</dict>
</plist>
PLIST
        cp .build/release/OpenClawActivity /Applications/OpenClawActivity.app/Contents/MacOS/OpenClawActivity
        chmod +x /Applications/OpenClawActivity.app/Contents/MacOS/OpenClawActivity
      EOS
    ]
  }

  uninstall delete: "/Applications/OpenClawActivity.app"
end
