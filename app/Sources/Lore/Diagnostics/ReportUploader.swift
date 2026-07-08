import Foundation

/// Where a problem report goes and the token it carries (design §8). The token
/// ships inside every copy of the app, so it is **public by construction** —
/// `strings` on the binary yields it. It is a bot filter, not a secret: the
/// receiver grants it exactly one power, append a rate-limited size-capped
/// report; it cannot read, list, or overwrite. See the receiver's README.
enum ReportEndpoint {
    /// The receiver's `POST /report` route.
    static let url = URL(string: "https://reports.dev.cognition.design/report")!

    /// PUBLIC bot-filter token, compiled into the client on purpose (design §8).
    /// Not a secret — do not treat it as one. The real value is injected by the
    /// release process; this placeholder is replaced in place.
    /// INJECT-TOKEN-HERE
    static let token = "LORE_REPORT_TOKEN_PLACEHOLDER"
}

/// Posts a `ProblemReport` to the receiver and returns the human-quotable Report
/// ID, or a typed error. The report is serialized once, by `ProblemReport`, so
/// the bytes posted here are byte-for-byte the bytes the preview showed the user
/// (the honesty contract, design §7). `URLSession` is injected so tests drive a
/// stub protocol and never touch the network.
struct ReportUploader: Sendable {
    var endpoint: URL = ReportEndpoint.url
    var token: String = ReportEndpoint.token
    var session: URLSession = .shared
    var timeout: TimeInterval = 20

    enum UploadError: Error, LocalizedError, Equatable {
        /// The encoded body exceeds `ProblemReport.maxPayloadBytes`. Caught here,
        /// before the network, so the user gets a clear message instead of the
        /// server's 413.
        case tooLarge(bytes: Int)
        /// The transport failed (offline, timeout, DNS).
        case transport
        /// The server answered with a non-2xx status.
        case server(status: Int)
        /// A 2xx with a body we could not read an `id` out of.
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .tooLarge(let bytes):
                let kb = bytes / 1024
                return "This report is too large to send (\(kb) KB). Please try again with a shorter message."
            case .transport:
                return "Couldn't reach the report server. Check your connection and try again."
            case .server(let status):
                return "The report server returned an error (HTTP \(status)). Please try again."
            case .malformedResponse:
                return "The report server sent back an unexpected response. Please try again."
            }
        }
    }

    /// Upload the report. Returns the Report ID (e.g. `NNGEB8YS`) the user quotes.
    func upload(_ report: ProblemReport) async throws -> String {
        let body = try report.encoded()
        guard body.count <= ProblemReport.maxPayloadBytes else {
            throw UploadError.tooLarge(bytes: body.count)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Lore-Token")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UploadError.transport
        }

        guard let http = response as? HTTPURLResponse else {
            throw UploadError.malformedResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw UploadError.server(status: http.statusCode)
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = json["id"] as? String, !id.isEmpty
        else {
            throw UploadError.malformedResponse
        }
        return id
    }
}
