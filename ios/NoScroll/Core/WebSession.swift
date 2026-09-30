import Foundation

/// One signed-in account of one service.
///
/// Its `id` names a persistent `WKWebsiteDataStore(forIdentifier:)`, which is
/// why the deployment target is iOS 17: before iOS 17 every non-default store
/// is ephemeral, so accounts would either share one cookie jar (and collide) or
/// lose their session on every launch. Accounts are managed by AppState.
struct WebSession: Identifiable, Hashable, Codable {
    let id: UUID
    var service: String
    /// The username the service shows once signed in; empty until then.
    var displayName: String
}
