import LocalAuthentication

/// Touch ID / password gate for the Hidden scope. Wraps the callback-based
/// `LAContext` API in an `async` continuation so call sites can simply
/// `await` the result (see `SidebarView` and the locked-grid placeholder in
/// `MicroGridView`).
enum HiddenGate {
    static func authenticate() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return await withCheckedContinuation { cont in
            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: "view your Hidden items") { ok, _ in
                cont.resume(returning: ok)
            }
        }
    }
}
