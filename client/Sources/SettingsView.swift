import SwiftUI

struct SettingsView: View {
    let monitor: ActivityMonitor
    let onClose: () -> Void

    @State private var serverURL: String
    @State private var gatewayToken: String
    @State private var infoMessage: String?
    @State private var errorMessage: String?

    init(monitor: ActivityMonitor, onClose: @escaping () -> Void) {
        self.monitor = monitor
        self.onClose = onClose
        _serverURL = State(initialValue: monitor.serverURL)
        _gatewayToken = State(initialValue: monitor.currentGatewayToken())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                Section("Activity API") {
                    TextField("http://localhost:19789", text: $serverURL)
                        .textFieldStyle(.roundedBorder)
                    Text("Used by this menu bar client to fetch /api/status.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("OpenClaw Gateway Token") {
                    SecureField("gateway.auth.token", text: $gatewayToken)
                    Text("Saved to ~/.openclaw/openclaw.json (gateway.auth.token). Restart openclaw-activity-server after changing it.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundColor(.red)
            } else if let infoMessage {
                Text(infoMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    onClose()
                }
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 320)
    }

    private func save() {
        errorMessage = nil
        infoMessage = nil

        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedURL.isEmpty {
            monitor.clearServerURLOverride()
        } else {
            monitor.setServerURL(trimmedURL)
        }

        do {
            try monitor.setGatewayToken(gatewayToken)
            infoMessage = "Saved. Restart openclaw-activity-server to apply token changes."
            onClose()
        } catch {
            errorMessage = "Failed to save token: \(error.localizedDescription)"
        }
    }
}
