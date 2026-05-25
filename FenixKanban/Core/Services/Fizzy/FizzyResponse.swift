import Foundation

/// Wraps a decoded body + the ETag the server sent for it. `body == nil`
/// signals a 304 Not Modified — caller already has the latest version.
struct FizzyResponse<T> {
    let body: T?
    let etag: String?
}
