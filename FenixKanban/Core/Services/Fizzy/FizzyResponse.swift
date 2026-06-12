import Foundation

/// Wraps a decoded body + the ETag the server sent for it. `body == nil`
/// signals a 304 Not Modified — caller already has the latest version.
struct FizzyResponse<T> {
    let body: T?
    let etag: String?
}

/// Result of a conditional paginated collection fetch (task #61).
/// `items == nil` signals a 304 on page 1 — the whole collection is
/// unchanged and the caller should reuse its cached copy. `singlePage`
/// is true when page 1 carried no `rel="next"` link; conditional requests
/// should only be issued against collections that were single-page on the
/// previous fetch.
struct FizzyPagedResult<Element> {
    let items: [Element]?
    let etag: String?
    let singlePage: Bool
}
