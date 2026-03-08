class OpenclawActivityServer < Formula
  desc "Local API server for OpenClaw agent activity monitoring"
  homepage "https://github.com/avchaykin/openclaw-remote-activity"
  url "https://github.com/avchaykin/openclaw-remote-activity.git",
      tag: "v0.1.0"
  license "MIT"

  depends_on "node"

  def install
    cd "server" do
      system "npm", "install", "--production=false"
      system "npm", "run", "build"
      system "npm", "prune", "--production"

      libexec.install "dist", "node_modules", "package.json"
    end

    # Create wrapper script
    (bin/"openclaw-activity-server").write <<~BASH
      #!/bin/bash
      exec "#{Formula["node"].opt_bin}/node" "#{libexec}/dist/index.js" "$@"
    BASH
  end

  service do
    run [opt_bin/"openclaw-activity-server"]
    keep_alive true
    working_dir var
    log_path var/"log/openclaw-activity-server.log"
    error_log_path var/"log/openclaw-activity-server.log"
    environment_variables \
      OPENCLAW_GATEWAY_URL: "ws://127.0.0.1:18789",
      OPENCLAW_GATEWAY_TOKEN: "",
      ACTIVITY_PORT: "19789"
  end

  def caveats
    <<~EOS
      To configure the gateway token, edit the service plist or set env vars:

        export OPENCLAW_GATEWAY_TOKEN="your_token"

      Or edit the launchctl plist:
        #{launchd_service_path}

      Start the service:
        brew services start openclaw-activity-server

      Test:
        curl http://localhost:19789/api/health
    EOS
  end

  test do
    assert_match "listening on", shell_output("#{bin}/openclaw-activity-server &; sleep 2; kill %1 2>/dev/null; echo done")
  end
end
