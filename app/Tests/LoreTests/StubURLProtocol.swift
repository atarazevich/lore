import Foundation

/// A `URLProtocol` that answers requests from memory so uploader tests never
/// touch the network. It records the request it saw (including the body, which
/// `URLProtocol` exposes as a stream once the request is enqueued) and returns a
/// canned status + body chosen by `responder`.
final class StubURLProtocol: URLProtocol {

    /// The last request the stub was asked to load, and its body (read off the
    /// body stream, since `URLSession` moves `httpBody` there before we see it).
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    /// Decides the canned (status, body) for a request. Default: 200 + valid id.
    nonisolated(unsafe) static var responder: (URLRequest) -> (Int, Data) = { _ in
        (200, Data(#"{"id":"NNGEB8YS"}"#.utf8))
    }

    static func reset() {
        lastRequest = nil
        lastBody = nil
        responder = { _ in (200, Data(#"{"id":"NNGEB8YS"}"#.utf8)) }
    }

    /// A session configured to route every request through this stub.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = Self.bodyData(from: request)

        let (statusCode, body) = Self.responder(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// `httpBody` is usually nil by the time a request reaches a protocol — the
    /// bytes live on `httpBodyStream`. Read whichever is present.
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
