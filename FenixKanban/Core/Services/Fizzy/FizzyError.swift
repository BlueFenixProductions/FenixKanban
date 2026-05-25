import Foundation

/// Typed errors surfaced by ``FizzyClient`` for callers (sync engine, UI).
///
/// `network` wraps the underlying `URLError`; `decoding` wraps the JSON parse
/// failure. Everything else is a normalized representation of a Fizzy HTTP
/// response.
enum FizzyError: Error, Equatable {
    case unauthorized              // 401 — token revoked/expired
    case forbidden                 // 403 — token lacks scope
    case notFound                  // 404 — resource gone or never existed
    case validation([String])      // 422 — `{ "errors": { field: [msg, ...] } }` flattened to "field: msg" strings
    case rateLimited(retryAfter: TimeInterval)   // 429 — honor Retry-After
    case server(statusCode: Int)   // 5xx
    case network(URLError)         // URLSession-level (DNS, timeout, offline)
    case decoding(String)          // JSON parse failure; carries the description (Error isn't Equatable)
    case unexpectedStatus(Int)     // catch-all

    /// Init from a raw HTTP status + optional response body. Used for non-429 statuses.
    init(httpStatus: Int, body: Data?) {
        switch httpStatus {
        case 401: self = .unauthorized
        case 403: self = .forbidden
        case 404: self = .notFound
        case 422: self = .validation(Self.parseValidationErrors(body))
        case 500...599: self = .server(statusCode: httpStatus)
        default:  self = .unexpectedStatus(httpStatus)
        }
    }

    /// Init for 429 specifically — extracts Retry-After.
    init(httpStatus: Int, retryAfter: String?) {
        precondition(httpStatus == 429, "rate-limit initializer only valid for 429")
        let secs = retryAfter.flatMap { TimeInterval($0) } ?? 60
        self = .rateLimited(retryAfter: secs)
    }

    /// Flattens `{ "errors": { "title": ["msg1", "msg2"], "tags": ["msg3"] } }`
    /// into `["title: msg1", "title: msg2", "tags: msg3"]`. Returns empty array
    /// on any parse failure — 422 is still .validation, just without details.
    private static func parseValidationErrors(_ body: Data?) -> [String] {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let errors = json["errors"] as? [String: [String]]
        else { return [] }
        return errors.flatMap { field, msgs in msgs.map { "\(field): \($0)" } }
    }
}
