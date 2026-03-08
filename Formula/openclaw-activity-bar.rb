class OpenclawActivityBar < Formula
  desc "macOS menu bar client for OpenClaw agent activity monitoring"
  homepage "https://github.com/avchaykin/openclaw-remote-activity"
  url "https://github.com/avchaykin/openclaw-remote-activity.git",
      tag:      "v0.1.0",
      revision: "HEAD"
  license "MIT"

  depends_on :macos

  def install
    cd "client" do
      system "swift", "build", "-c", "release", "--disable-sandbox"
      bin.install ".build/release/OpenClawActivity" => "openclaw-activity-bar"
    end
  end

  service do
    run [opt_bin/"openclaw-activity-bar"]
    keep_alive true
    process_type :interactive
    environment_variables \
      HOME: ENV["HOME"]
  end

  def caveats
    <<~EOS
      The menu bar app needs to run as an interactive process.

      Start it:
        brew services start openclaw-activity-bar

      Or run directly:
        openclaw-activity-bar

      Configure server URL (default: http://localhost:19789):
        defaults write com.openclaw.activity serverURL "http://localhost:19789"

      Make sure openclaw-activity-server is running first:
        brew services start openclaw-activity-server
    EOS
  end

  test do
    assert_predicate bin/"openclaw-activity-bar", :exist?
  end
end
