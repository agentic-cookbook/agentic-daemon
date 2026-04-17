import Foundation

/// Synchronous HTTP client for CLI tools and functional tests.
/// Connects to a daemon's HTTP server for querying status.
public struct DaemonHTTPClient: Sendable {
    public let baseURL: String
    private let timeout: TimeInterval

    public init(baseURL: String, timeout: TimeInterval = 2) {
        self.baseURL = baseURL
        self.timeout = timeout
    }

    /// GET a path and decode the JSON response. Returns nil on any failure.
    public func get<T: Decodable>(_ path: String, as type: T.Type) -> T? {
        guard let data = getData(path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    /// GET a path and return the raw response body. Returns nil on any failure.
    public func getData(_ path: String) -> Data? {
        guard let url = URL(string: "\(baseURL)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                box.setValue(data)
            }
            sem.signal()
        }
        task.resume()
        sem.wait()
        return box.value
    }
}

/// Lock-protected container for bridging URLSession's `@Sendable` completion
/// back to a synchronous caller without tripping Swift 6's capture-mutation
/// check.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Data?
    var value: Data? { lock.withLock { _value } }
    func setValue(_ v: Data?) { lock.withLock { _value = v } }
}
