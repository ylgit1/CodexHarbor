/// Distinguishes an intentional, live system-proxy takeover from a stale
/// recovery snapshot. Keeping a snapshot while actively proxying is required:
/// it lets Harbor restore the user's original macOS settings on shutdown.
public enum HarborProxyRecoveryPolicy {
    /// A recovery warning is appropriate only if a saved snapshot exists but
    /// Harbor no longer has a live, owned system-proxy connection.
    public static func requiresRecovery(
        hasBackup: Bool,
        isRunning: Bool,
        isSystemManaged: Bool,
        ownsSystemProxy: Bool,
        currentUsesManagedListener: Bool = true
    ) -> Bool {
        guard hasBackup else { return false }
        if isRunning && isSystemManaged && ownsSystemProxy { return false }
        // A different client has replaced every Harbor listener. The stale
        // snapshot can be discarded without changing that client's settings.
        if !ownsSystemProxy && !currentUsesManagedListener { return false }
        return true
    }

    /// Always restore a saved system-proxy snapshot *before* stopping Xray,
    /// including when the currently owned connection is healthy.
    public static func mustRestoreBeforeStop(hasBackup: Bool) -> Bool {
        hasBackup
    }
}
