import Foundation

// MARK: - Models

struct SessionInfo: Codable, Identifiable {
    let key: String
    let agentId: String
    let kind: String
    let ageMs: Int
    let active: Bool
    let model: String?

    var id: String { key }
}

struct ActivitySummary: Codable {
    let totalSessions: Int
    let activeSessions: Int
    let idleSessions: Int
}

struct ToolActivity: Codable, Identifiable {
    let ts: Int
    let sessionKey: String?
    let tool: String
    let phase: String

    var id: String { "\(ts)-\(tool)-\(phase)-\(sessionKey ?? "")" }
}

struct ActivityState: Codable {
    let connected: Bool
    let active: Bool
    let currentPhase: String?
    let phaseTs: Int?
    let sessions: [SessionInfo]
    let summary: ActivitySummary
    let ts: Int
    let gatewayEvents: Int
    let toolLog: [ToolActivity]
    let mode: String?
}

struct HealthResponse: Codable {
    let ok: Bool
    let gateway: String
    let uptime: Int
    let mode: String?
}

extension ActivityState {
    static let disconnected = ActivityState(
        connected: false,
        active: false,
        currentPhase: "idle",
        phaseTs: nil,
        sessions: [],
        summary: ActivitySummary(totalSessions: 0, activeSessions: 0, idleSessions: 0),
        ts: 0,
        gatewayEvents: 0,
        toolLog: [],
        mode: nil
    )
}

// MARK: - Monitor

final class ActivityMonitor {
    private(set) var serverURL: String
    private(set) var serverURLSource: String
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var eventSource: URLSessionDataTask?

    private static let configKey = "serverURL"
    private static let defaultServerURL = "http://localhost:19789"
    private static let preferredDomains = [
        "com.openclaw.activity",
        "OpenClawActivity",
        "openclaw-activity-bar"
    ]
    private static let openClawConfigPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".openclaw", isDirectory: true)
        .appendingPathComponent("openclaw.json", isDirectory: false)

    var state: ActivityState = .disconnected {
        didSet {
            onStateChange?()
        }
    }

    var onStateChange: (() -> Void)?

    init() {
        self.serverURL = Self.defaultServerURL
        self.serverURLSource = "default"

        let defaults = UserDefaults.standard

        self.pollInterval = defaults.double(forKey: "pollInterval").nonZero ?? 2.0
        reloadConfiguration()
        print("[OpenClawActivity] serverURL=\(self.serverURL) source=\(self.serverURLSource)")
    }

    func reloadConfiguration() {
        if let envURL = ProcessInfo.processInfo.environment["OPENCLAW_ACTIVITY_SERVER_URL"]?.trimmedNonEmpty {
            setResolvedServerURL(envURL, source: "env:OPENCLAW_ACTIVITY_SERVER_URL")
            return
        }

        for domain in Self.preferredDomains {
            if let value = UserDefaults(suiteName: domain)?.string(forKey: Self.configKey)?.trimmedNonEmpty {
                setResolvedServerURL(value, source: "defaults:\(domain)")
                return
            }
        }

        if let standardURL = UserDefaults.standard.string(forKey: Self.configKey)?.trimmedNonEmpty {
            setResolvedServerURL(standardURL, source: "defaults:standard")
            return
        }

        setResolvedServerURL(Self.defaultServerURL, source: "default")
    }

    func setServerURL(_ rawValue: String) {
        guard let normalized = Self.normalizeServerURL(rawValue) else { return }

        let defaults = UserDefaults.standard
        defaults.set(normalized, forKey: Self.configKey)

        for domain in Self.preferredDomains {
            let domainDefaults = UserDefaults(suiteName: domain)
            domainDefaults?.set(normalized, forKey: Self.configKey)
        }

        defaults.synchronize()
        reloadConfiguration()
        poll()
    }

    func clearServerURLOverride() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.configKey)

        for domain in Self.preferredDomains {
            let domainDefaults = UserDefaults(suiteName: domain)
            domainDefaults?.removeObject(forKey: Self.configKey)
        }

        defaults.synchronize()
        reloadConfiguration()
        poll()
    }

    func currentGatewayToken() -> String {
        do {
            let config = try readOpenClawConfig()
            let gateway = config["gateway"] as? [String: Any]
            let auth = gateway?["auth"] as? [String: Any]
            return (auth?["token"] as? String) ?? ""
        } catch {
            return ""
        }
    }

    func setGatewayToken(_ rawValue: String) throws {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var config = try readOpenClawConfig()
        var gateway = (config["gateway"] as? [String: Any]) ?? [:]
        var auth = (gateway["auth"] as? [String: Any]) ?? [:]

        if trimmed.isEmpty {
            auth.removeValue(forKey: "token")
        } else {
            auth["token"] = trimmed
        }

        gateway["auth"] = auth
        config["gateway"] = gateway
        try writeOpenClawConfig(config)
    }

    func start() {
        poll() // immediate
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        eventSource?.cancel()
        eventSource = nil
    }

    private func poll() {
        guard let url = URL(string: "\(serverURL)/api/status") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if error != nil {
                DispatchQueue.main.async {
                    self.state = .disconnected
                }
                return
            }

            guard let data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                DispatchQueue.main.async {
                    self.state = .disconnected
                }
                return
            }

            do {
                let newState = try JSONDecoder().decode(ActivityState.self, from: data)
                DispatchQueue.main.async {
                    self.state = newState
                }
            } catch {
                // Keep current state on decode error
            }
        }.resume()
    }

    private func setResolvedServerURL(_ value: String, source: String) {
        self.serverURL = value
        self.serverURLSource = source
        print("[OpenClawActivity] serverURL=\(self.serverURL) source=\(self.serverURLSource)")
    }

    private static func normalizeServerURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return nil
        }

        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = components.path.isEmpty ? "" : "/\(components.path)"
        components.path = basePath

        guard let normalized = components.url?.absoluteString else { return nil }
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func readOpenClawConfig() throws -> [String: Any] {
        let path = Self.openClawConfigPath
        guard FileManager.default.fileExists(atPath: path.path) else {
            return [:]
        }

        let data = try Data(contentsOf: path)
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    private func writeOpenClawConfig(_ config: [String: Any]) throws {
        let path = Self.openClawConfigPath
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    }
}

// MARK: - Helpers

private extension Double {
    var nonZero: Double? {
        self > 0 ? self : nil
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
