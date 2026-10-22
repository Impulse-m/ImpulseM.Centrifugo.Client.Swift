import Foundation

// The identity of a connection: the user and auth class that the server
// confirmed in the connect reply and in each refresh reply. The client holds it on syncQueue
// only, and reports it through `CentrifugeClientDelegate.onAuth`.

/// The user and auth class the server confirmed for the connection.
internal struct ConnectionIdentity {
    internal private(set) var user: String = ""
    internal private(set) var authClass: String = ""


    /// Takes the identity of a connect reply. A connect always reports the identity, so the
    /// caller reports it on every connect.
    internal mutating func applyConnect(user: String, authClass: String) {
        self.user = user
        self.authClass = authClass
    }


    /// Takes the identity of a refresh reply. Returns whether it changed the identity; the caller
    /// reports only a change.
    internal mutating func applyRefresh(user: String, authClass: String) -> Bool {
        let changed: Bool = user != self.user || authClass != self.authClass
        self.user = user
        self.authClass = authClass
        return changed
    }
}
