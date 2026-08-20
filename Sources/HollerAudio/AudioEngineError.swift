public enum AudioEngineError: Error, Equatable, Sendable {
    case formatUnavailable
    case converterUnavailable
    case bufferAllocationFailed
}
