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

struct ActivityState: Codable {
    let connected: Bool
    let active: Bool
    let sessions: [SessionInfo]
    let summary: ActivitySummary
    let ts: Int
    let gatewayEvents: Int
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
        sessions: [],
        summary: ActivitySummary(totalSessions: 0, activeSessions: 0, idleSessions: 0),
        ts: 0,
        gatewayEvents: 0
    )
}

// MARK: - Monitor

final class ActivityMonitor {
    private let serverURL: String
    private let pollInterval: TimeInterval
    private var timer: Timer?
    private var eventSource: URLSessionDataTask?

    var state: ActivityState = .disconnected {
        didSet {
            onStateChange?()
        }
    }

    var onStateChange: (() -> Void)?

    init() {
        let defaults = UserDefaults.standard
        self.serverURL = defaults.string(forKey: "serverURL") ?? "http://localhost:19789"
        self.pollInterval = defaults.double(forKey: "pollInterval").nonZero ?? 2.0
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
}

// MARK: - Helpers

private extension Double {
    var nonZero: Double? {
        self > 0 ? self : nil
    }
}
