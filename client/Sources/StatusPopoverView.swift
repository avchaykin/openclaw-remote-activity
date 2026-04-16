import SwiftUI
import AppKit

struct StatusPopoverView: View {
    let monitor: ActivityMonitor

    @State private var state: ActivityState = .disconnected
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("🦞 OpenClaw Activity")
                    .font(.headline)
                Spacer()
                StatusBadge(state: state)
            }

            Divider()

            if !state.connected {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Not connected to activity server")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Ensure openclaw-activity-server is running")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                // Summary
                HStack(spacing: 16) {
                    StatBlock(value: "\(state.summary.totalSessions)", label: "Sessions")
                    StatBlock(value: "\(state.summary.activeSessions)", label: "Active", color: state.summary.activeSessions > 0 ? Color(nsColor: .activityDarkGreen) : .secondary)
                    StatBlock(value: "\(state.summary.idleSessions)", label: "Idle")
                }
                .frame(maxWidth: .infinity)

                HStack {
                    Text("Phase: \(phaseLabel(state.currentPhase))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                Divider()
                Text("Tool Activity")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if state.mode == "cli-fallback" {
                    Text("Tool log available in WebSocket mode (with OPENCLAW_GATEWAY_TOKEN)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if state.toolLog.isEmpty {
                    Text("No recent tool activity")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(state.toolLog.prefix(4)) { item in
                        ToolLogRow(item: item)
                    }
                }

                // Active sessions
                if !state.sessions.filter({ $0.active }).isEmpty {
                    Divider()
                    Text("Active Sessions")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(state.sessions.filter { $0.active }) { session in
                        SessionRow(session: session)
                    }
                }
            }

            Spacer(minLength: 0)

            // Footer
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Gateway: \(state.connected ? "connected" : "disconnected")")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Quit") {
                        NSApp.terminate(nil)
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }

                Text("API: \(monitor.serverURL)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Source: \(monitor.serverURLSource)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360, height: 330)
        .onReceive(timer) { _ in
            state = monitor.state
        }
        .onAppear {
            state = monitor.state
        }
    }
}

// MARK: - Subviews

struct StatusBadge: View {
    let state: ActivityState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(badgeText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var badgeColor: Color {
        if !state.connected { return .red }
        if state.active { return Color(nsColor: .activityDarkGreen) }
        return .white
    }

    private var badgeText: String {
        if !state.connected { return "Offline" }
        if state.active {
            switch state.currentPhase {
            case "tooling": return "Tooling"
            case "thinking": return "Thinking"
            case "responding": return "Responding"
            default: return "Active"
            }
        }
        return "Idle"
    }
}

private func phaseLabel(_ phase: String?) -> String {
    switch phase {
    case "tooling": return "Tooling"
    case "thinking": return "Thinking"
    case "responding": return "Responding"
    default: return "Idle"
    }
}

struct StatBlock: View {
    let value: String
    let label: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.bold())
                .foregroundColor(color)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct ToolLogRow: View {
    let item: ToolActivity

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.caption2)
                .foregroundColor(Color(nsColor: .activityDarkGreen))
            Text("\(item.tool) · \(item.phase)")
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(formatAge(item.ts))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func formatAge(_ ts: Int) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince1970) - (ts / 1000))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }
}

struct SessionRow: View {
    let session: SessionInfo

    var body: some View {
        HStack {
            Circle()
                .fill(Color(nsColor: .activityDarkGreen))
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.kind)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(session.agentId + (session.model.map { " · \($0)" } ?? ""))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(formatAge(session.ageMs))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private func formatAge(_ ms: Int) -> String {
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        return "\(minutes)m ago"
    }
}

extension NSColor {
    static let activityDarkGreen = NSColor(calibratedRed: 0.0, green: 0.45, blue: 0.2, alpha: 1.0)
}
