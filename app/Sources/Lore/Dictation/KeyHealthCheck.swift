import Foundation

/// Verdict of the OpenAI key liveness probe (#50).
enum KeyHealthStatus: Equatable, Sendable {
    /// The API accepted the key.
    case ok
    /// The API rejected the key (HTTP 401) — revoked or mistyped.
    case invalid
    /// Inconclusive (network error, timeout, 5xx, rate limit) — no verdict,
    /// the UI must not alarm the user over a flaky connection.
    case unknown
}

/// Lightweight OpenAI key liveness check: `GET /v1/models` with the bearer
/// key spends no tokens and returns 401 for a dead key. Deliberately not a
/// third completion client — a bare GET needs none of that machinery (#50).
enum KeyHealthCheck {
    private static let endpoint = URL(string: "https://api.openai.com/v1/models")!

    /// Pure status → verdict mapping, unit-testable without the network.
    /// Only a definitive 401 condemns a key. Accepted blind spot: a 403
    /// (key alive but blocked for the endpoint/org) reads as `.unknown`,
    /// not `.invalid` — staying silent beats a false "key rejected".
    static func classify(statusCode: Int?) -> KeyHealthStatus {
        switch statusCode {
        case .some(200...299): return .ok
        case .some(401): return .invalid
        default: return .unknown
        }
    }

    static func probe(apiKey: String) async -> KeyHealthStatus {
        var request = URLRequest(url: endpoint, timeoutInterval: 10)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return classify(statusCode: (response as? HTTPURLResponse)?.statusCode)
        } catch {
            return .unknown // network error/timeout — no verdict
        }
    }
}
