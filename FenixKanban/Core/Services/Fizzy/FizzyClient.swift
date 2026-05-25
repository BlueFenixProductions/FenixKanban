import Foundation

/// HTTP client for the Fizzy API.
///
/// Adds `Authorization: Bearer <token>` and `Accept: application/json` to
/// every request. Interpolates `accountSlug` into paths unless the path begins
/// with `/my` (Fizzy's identity/profile namespace is not account-scoped).
final class FizzyClient: Sendable {

    private let baseURL: URL
    private let accessToken: String
    private let accountSlug: String
    private let urlSession: URLSession

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init(
        baseURL: URL,
        accessToken: String,
        accountSlug: String,
        urlSession: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.accountSlug = accountSlug
        self.urlSession = urlSession
    }

    /// GET a JSON resource. Returns the decoded body — ETag handling lands in Task 6.
    func get<T: Decodable & Sendable>(_ path: String, as: T.Type) async throws -> T {
        let response = try await getWithETag(path, etag: nil, as: T.self)
        guard let body = response.body else {
            // 304 with no prior etag shouldn't happen — caller asked for fresh data.
            throw FizzyError.unexpectedStatus(304)
        }
        return body
    }

    /// GET with explicit ETag handling. Used by the sync engine; sends
    /// `If-None-Match` if `etag != nil`, returns `body == nil` on 304.
    func getWithETag<T: Decodable & Sendable>(
        _ path: String,
        etag: String?,
        as: T.Type
    ) async throws -> FizzyResponse<T> {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FizzyError.unexpectedStatus(0)
        }

        switch http.statusCode {
        case 200:
            let decoded = try Self.decoder.decode(T.self, from: data)
            return FizzyResponse(body: decoded, etag: http.value(forHTTPHeaderField: "ETag"))
        case 304:
            return FizzyResponse(body: nil, etag: http.value(forHTTPHeaderField: "ETag") ?? etag)
        case 429:
            throw FizzyError(httpStatus: 429, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        default:
            throw FizzyError(httpStatus: http.statusCode, body: data)
        }
    }

    /// POST a JSON body. Fizzy returns 201 + Location header (no body); this
    /// method follows the Location with a GET and returns the decoded resource
    /// so callers get the new ID, ETag, and any server-generated fields in one
    /// call.
    func post<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FizzyError.unexpectedStatus(0)
        }

        switch http.statusCode {
        case 201:
            guard let locationString = http.value(forHTTPHeaderField: "Location"),
                  let location = URL(string: locationString) else {
                throw FizzyError.unexpectedStatus(201)
            }
            return try await followLocation(location, as: T.self)
        case 429:
            throw FizzyError(httpStatus: 429, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        default:
            throw FizzyError(httpStatus: http.statusCode, body: data)
        }
    }

    /// Internal: GET an absolute URL (skipping the slug interpolation) and
    /// decode the body. Used by `post` to follow `Location`.
    private func followLocation<T: Decodable & Sendable>(_ url: URL, as: T.Type) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FizzyError.unexpectedStatus(0)
        }
        guard http.statusCode == 200 else {
            throw FizzyError(httpStatus: http.statusCode, body: data)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    // MARK: - URL construction

    /// Builds the absolute URL for a path. Paths starting with `/my/` skip the
    /// account-slug prefix (Fizzy convention — `/my/identity` is not scoped).
    /// The trailing slash avoids false matches like `/myth-busters`.
    private func url(for path: String) -> URL {
        precondition(path.hasPrefix("/"), "FizzyClient paths must begin with `/`")
        let prefix = path.hasPrefix("/my/") ? "" : "/\(accountSlug)"
        return baseURL.appending(path: "\(prefix)\(path)")
    }
}
