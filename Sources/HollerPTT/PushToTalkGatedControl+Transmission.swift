import HollerCore

/// System transmission callbacks for PushToTalkGatedControl (same actor; split for file size): forwarded to the
/// coordinator only while the membership they belong to is the current one.
extension PushToTalkGatedControl {
    func handleTransmission(_ event: PushToTalkEvent) async {
        switch event {
        case let .beginTransmittingRequested(id) where id == channelID && joined:
            let session = channelSession
            systemTransmitting = true
            transmitSession = session
            transmitGeneration += 1
            stopRequested = false
            stopAttempts = 0
            await inner.press()
            // the membership ended while the press was in flight
            if session != channelSession { await inner.release() }
        case let .endTransmittingRequested(id) where id == channelID && joined && transmitSession == channelSession:
            systemTransmitting = false
            stopRequested = false
            await inner.release()
            refreshContinuation.yield()  // speaker mirroring was deferred during the transmission
        case let .beginTransmitFailed(id) where id == channelID && joined && transmitSession == channelSession:
            systemTransmitting = false
            await inner.release()  // the coordinator must not wait for a confirmation that will not come
            refreshContinuation.yield()
        case let .stopTransmitFailed(id) where id == channelID && joined && transmitSession == channelSession
            && stopGeneration == transmitGeneration:  // a refusal answers the stop of the transmission it was asked for
            stopRequested = false
            await inner.release()  // the coordinator must not keep capture and the floor meanwhile…
            // …and the coordinator may already be idle (it reports state before the notice that asked for the stop),
            // so nothing else would ask again: ask now, bounded.
            if systemTransmitting && stopAttempts < Self.maxStopAttempts { await requestSystemStop() }
        default: break
        }
    }
}
