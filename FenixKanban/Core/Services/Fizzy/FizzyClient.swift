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
    private let clock: any Clock<Duration> & Sendable

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
        urlSession: URLSession = .shared,
        clock: any Clock<Duration> & Sendable = ContinuousClock()
    ) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.accountSlug = accountSlug
        self.urlSession = urlSession
        self.clock = clock
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

    /// GET a paginated collection, following the `Link: <url>; rel="next"`
    /// response header until exhausted. Fizzy paginates every list endpoint
    /// (dynamic page size — early pages are smaller); pages 2+ are requested
    /// at the exact absolute URL from the header, which is already
    /// account-scoped, so no slug interpolation happens on follows.
    func getAllPages<Element: Decodable & Sendable>(
        _ path: String,
        as: [Element].Type
    ) async throws -> [Element] {
        var items: [Element] = []
        var nextURL: URL? = url(for: path)

        while let pageURL = nextURL {
            var request = URLRequest(url: pageURL)
            request.httpMethod = "GET"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, http) = try await performWithRetry(request)
            switch http.statusCode {
            case 200:
                items += try Self.decoder.decode([Element].self, from: data)
                nextURL = nextPageURL(from: http.value(forHTTPHeaderField: "Link"))
            case 429:
                throw FizzyError(httpStatus: 429, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            default:
                throw FizzyError(httpStatus: http.statusCode, body: data)
            }
        }
        return items
    }

    /// Parses `<https://…?page=2>; rel="next"` out of a `Link` header.
    /// Returns nil when the header is absent, carries no rel="next" segment
    /// (e.g. only rel="prev" on the last page), or the next URL is not
    /// same-origin with `baseURL` — following a cross-origin link would hand
    /// the Bearer token to whatever host the header names.
    private func nextPageURL(from linkHeader: String?) -> URL? {
        guard let linkHeader else { return nil }
        for segment in linkHeader.split(separator: ",") {
            let parts = segment.split(separator: ";")
            guard let target = parts.first?.trimmingCharacters(in: .whitespaces),
                  target.hasPrefix("<"), target.hasSuffix(">") else { continue }
            let isNext = parts.dropFirst().contains {
                $0.trimmingCharacters(in: .whitespaces) == "rel=\"next\""
            }
            guard isNext, let next = URL(string: String(target.dropFirst().dropLast())) else { continue }
            guard next.scheme == baseURL.scheme,
                  next.host?.lowercased() == baseURL.host?.lowercased(),
                  next.port == baseURL.port else {
                return nil
            }
            return next
        }
        return nil
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

        let (data, http) = try await performWithRetry(request)

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

        let (data, http) = try await performWithRetry(request)

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

    /// PUT a JSON body. Returns the updated resource (200 + body, not 204).
    func put<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ path: String,
        body: Body,
        as: T.Type
    ) async throws -> T {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)

        let (data, http) = try await performWithRetry(request)

        switch http.statusCode {
        case 200:
            return try Self.decoder.decode(T.self, from: data)
        case 429:
            throw FizzyError(httpStatus: 429, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        default:
            throw FizzyError(httpStatus: http.statusCode, body: data)
        }
    }

    /// DELETE a resource. Returns on 204; throws on any other status.
    func delete(_ path: String) async throws {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, http) = try await performWithRetry(request)

        switch http.statusCode {
        case 204:
            return
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

        let (data, http) = try await performWithRetry(request)
        guard http.statusCode == 200 else {
            throw FizzyError(httpStatus: http.statusCode, body: data)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    // MARK: - Retry

    /// Performs the request with up to 3 retries on transient failures (URLError
    /// or 5xx). 4xx propagates immediately. Backoff: 1s, 2s, 4s (via the
    /// injected `Clock`, so tests can pass `ImmediateClock()` for instant runs).
    private func performWithRetry(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]

        for attempt in 0...delays.count {
            do {
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw FizzyError.unexpectedStatus(0)
                }
                if (500...599).contains(http.statusCode), attempt < delays.count {
                    try await clock.sleep(for: delays[attempt])
                    continue
                }
                return (data, http)
            } catch let error as URLError {
                if attempt < delays.count {
                    try await clock.sleep(for: delays[attempt])
                    continue
                }
                throw FizzyError.network(error)
            }
        }
        // Unreachable.
        throw FizzyError.unexpectedStatus(0)
    }

    // MARK: - URL construction

    /// Builds the absolute URL for a path. Paths starting with `/my/` skip the
    /// account-slug prefix (Fizzy convention — `/my/identity` is not scoped).
    /// The trailing slash avoids false matches like `/myth-busters`.
    ///
    /// Fizzy's `/my/identity` returns `slug` with a leading `/` (e.g.
    /// `"/897362094"`), so we normalize before interpolation — otherwise
    /// `combined` would start with `//` and parse as a protocol-relative URL.
    private func url(for path: String) -> URL {
        precondition(path.hasPrefix("/"), "FizzyClient paths must begin with `/`")
        let normalizedSlug = accountSlug.hasPrefix("/") ? String(accountSlug.dropFirst()) : accountSlug
        let prefix = path.hasPrefix("/my/") ? "" : "/\(normalizedSlug)"
        let combined = "\(prefix)\(path)"
        // Use URL(string:relativeTo:) to preserve query strings.
        // `URL.appending(path:)` percent-encodes `?` into the path component,
        // which prevents URLSession from splitting path/query correctly.
        if let url = URL(string: combined, relativeTo: baseURL) {
            return url.absoluteURL
        }
        // Fallback: percent-encode the path (no query) and append directly.
        return baseURL.appending(path: combined)
    }
}

// MARK: - Card actions (low-level support)

// These helpers live in this file (not FizzyClient+CardActions.swift) because
// they need private members: `url(for:)`, `performWithRetry`, `accessToken`,
// `baseURL`, `accountSlug`, and the shared encoder/decoder.
extension FizzyClient {

    /// POST that expects `204 No Content` and carries no body. Fizzy's card
    /// action endpoints (closure, not_now, watch, goldness, pin) respond 204
    /// rather than the `201 + Location` convention `post` implements.
    func postNoContent(_ path: String) async throws {
        try await postNoContent(path, bodyData: nil)
    }

    /// POST that expects `204 No Content` with a JSON body (triage, taggings,
    /// assignments).
    func postNoContent<Body: Encodable & Sendable>(_ path: String, body: Body) async throws {
        try await postNoContent(path, bodyData: Self.encoder.encode(body))
    }

    private func postNoContent(_ path: String, bodyData: Data?) async throws {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bodyData {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = bodyData
        }

        let (data, http) = try await performWithRetry(request)

        switch http.statusCode {
        case 204:
            return
        case 429:
            throw FizzyError(httpStatus: 429, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        default:
            throw FizzyError(httpStatus: http.statusCode, body: data)
        }
    }

    /// GET an account-scoped `/my/…` path. `url(for:)` deliberately skips the
    /// slug for `/my/` paths (`/my/identity` is unscoped), but a few endpoints
    /// — `GET /:account_slug/my/pins` per docs/api/sections/pins.md — use the
    /// `/my/` prefix *and* are account-scoped, so the slug is interpolated
    /// here explicitly.
    func getAccountScoped<T: Decodable & Sendable>(myPath path: String, as: T.Type) async throws -> T {
        precondition(path.hasPrefix("/my/"), "use get(_:as:) for non-/my/ paths")
        let normalizedSlug = accountSlug.hasPrefix("/") ? String(accountSlug.dropFirst()) : accountSlug
        let scoped = "/\(normalizedSlug)\(path)"
        guard let scopedURL = URL(string: scoped, relativeTo: baseURL)?.absoluteURL else {
            throw FizzyError.unexpectedStatus(0)
        }

        var request = URLRequest(url: scopedURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, http) = try await performWithRetry(request)

        switch http.statusCode {
        case 200:
            return try Self.decoder.decode(T.self, from: data)
        case 429:
            throw FizzyError(httpStatus: 429, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        default:
            throw FizzyError(httpStatus: http.statusCode, body: data)
        }
    }
}
