/// Marker so the module exists on every platform; the adapter itself is iOS-only (PushToTalk framework).
public enum HollerPTTModule {
    #if os(iOS)
    public static let isAvailable = true
    #else
    public static let isAvailable = false
    #endif
}
