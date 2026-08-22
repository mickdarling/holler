import HollerCore

/// Event handling, rejoin, and speaker mirroring for PushToTalkGatedControl (same actor; split for file size).
extension PushToTalkGatedControl {
    func handle(_ event: PushToTalkEvent) async {
        defer { handledEventCount += 1 }
        switch event {
        case .joined, .joinFailed, .left, .leaveFailed: await handleMembership(event)
        case .beginTransmittingRequested, .endTransmittingRequested, .beginTransmitFailed, .stopTransmitFailed:
            await handleTransmission(event)
        case let .incomingSpeaker(id, _, displayName) where id == channelID:
            activeSpeaker = displayName  // the adapter just told the system this name (push path)
            pushedSpeaker = displayName  // keep showing it until the coordinator catches up (it may have no relay yet)
            speakerEpoch += 1
            refreshContinuation.yield()
        default: break
        }
    }

    private func handleMembership(_ event: PushToTalkEvent) async {
        switch event {
        case let .joined(id) where id == channelID && (joinsOutstanding > 0 || staleJoins > 0):
            await joinAnswered(accepted: true)
        case let .joinFailed(id) where id == channelID && (joinsOutstanding > 0 || staleJoins > 0):
            await joinAnswered(accepted: false)
        case let .left(id, .developerRequest) where id == channelID && pendingLeaves > 0: await ownLeaveSettled()
        case let .left(id, reason) where id == channelID: await membershipEnded(rejoin: reason.shouldRejoin)
        case let .leaveFailed(id) where id == channelID && pendingLeaves > 0: await ownLeaveRefused()
        default: break
        }
    }

    /// Only the answer to our latest join counts; earlier joins' answers are stale (a newer request supersedes them).
    private func joinAnswered(accepted: Bool) async {
        if staleJoins > 0 { await staleJoinAnswered(accepted: accepted); return }
        joinsOutstanding -= 1
        guard joinsOutstanding == 0 else { return }
        joined = accepted
        if !accepted, membershipSurvived {  // our leave was refused and now so was the new join: still a member
            membershipSurvived = false
            joined = true
            refreshContinuation.yield()
            return
        }
        if accepted {
            rejoinAfterAnswer = false
            membershipSurvived = false
            activeSpeaker = nil  // a fresh channel shows nobody
            pushedSpeaker = nil
            speakerEpoch += 1
            refreshContinuation.yield()
        } else if pendingLeaves > 0 {
            rejoinAfterLeave = true  // refused while our previous leave was still in flight
        } else if rejoinAfterAnswer {
            rejoinAfterAnswer = false  // the system dropped us again while this join was pending: try once more
            await rejoin()
        }
    }

    /// An answer to a join that stop() retired. Accepted while our leave is still in flight → nothing to do: the system
    /// processes our commands in order (that join, then the leave). Accepted after the leave already settled → the
    /// system made us a member again: leave once more, or during a restart count it as the surviving membership.
    private func staleJoinAnswered(accepted: Bool) async {
        staleJoins -= 1
        guard accepted else { releaseLeaveWaitersIfSettled(); return }
        if running || starting {
            if joinsOutstanding > 0 {
                membershipSurvived = true
            } else if !joined {
                joined = true
                refreshContinuation.yield()
            }
        } else if pendingLeaves == 0 && !endingSession {  // endSession() has not issued its leave yet: it will
            await issueLeave()
        } else {
            releaseLeaveWaitersIfSettled()
        }
    }

    /// Our own leave was confirmed: the membership it ends is already over.
    private func ownLeaveSettled() async {
        pendingLeaves -= 1
        releaseLeaveWaitersIfSettled()
        if rejoinAfterLeave { rejoinAfterLeave = false; await rejoin() }
    }

    /// The system refused our leave: we are still a member. Stopped gate → retry the leave (bounded); running gate
    /// (a restart superseded that session) → the membership is ours again, or a refused join is retried.
    private func ownLeaveRefused() async {
        pendingLeaves -= 1
        await leaveRefused()
    }

    /// The system refused (or could not be asked) to end our membership: we are still a member. During a restart the
    /// gate is not `running` yet but `starting`, and the replacement join may already be outstanding: same rules as running.
    func leaveRefused() async {
        if !running && !starting {
            if leaveAttempts < Self.maxLeaveAttempts {
                await issueLeave()
            } else {
                releaseLeaveWaitersIfSettled()  // exhausted: let a waiting stopAndAwaitLeave return
            }
            return
        }
        if rejoinAfterLeave { rejoinAfterLeave = false; await rejoin(); return }
        if joinsOutstanding > 0 { membershipSurvived = true; return }  // decided when that join is answered
        if !joined {  // nothing answered or pending: the system still holds our membership
            joined = true
            refreshContinuation.yield()
        }
    }

    /// The system ended our membership. Facts apply even while not running.
    private func membershipEnded(rejoin shouldRejoin: Bool) async {
        joined = false
        stopRequested = false
        channelSession += 1
        activeSpeaker = nil
        pushedSpeaker = nil
        speakerEpoch += 1
        if systemTransmitting {  // the system transmission ended with the membership: the coordinator must not keep
            systemTransmitting = false  // capturing and holding the relay floor
            await inner.release()
        }
        guard shouldRejoin else { return }
        if running { await rejoin() } else if starting { rejoinAfterStart = true }  // startup still suspended: after it
    }

    private func handleTransmission(_ event: PushToTalkEvent) async {
        switch event {
        case let .beginTransmittingRequested(id) where id == channelID && joined:
            let session = channelSession
            systemTransmitting = true
            transmitSession = session
            stopRequested = false
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
        case let .stopTransmitFailed(id) where id == channelID && joined && transmitSession == channelSession:
            stopRequested = false  // the system did not accept our stop; the next state/notice asks again…
            await inner.release()  // …but the coordinator must not keep capture and the floor meanwhile
        default: break
        }
    }

    /// One rejoin per system leave event. Under the lifecycle lock so it cannot straddle a stop()/start().
    func rejoin() async {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        guard running, !joined else { return }
        guard joinsOutstanding == 0 else { rejoinAfterAnswer = true; return }  // a join is unanswered: retry after it
        try? await issueJoin()  // a refusal arrives as .joinFailed; nothing retries until the next start/leave
    }

    /// stop(), then wait (bounded) until the system has confirmed or refused every leave we issued — so a caller that
    /// replaces this gate does not race its own next join against a membership that is still ending.
    public func stopAndAwaitLeave(timeout: Duration = .seconds(3)) async {
        await stop()
        guard pendingLeaves > 0 || staleJoins > 0 else { return }  // a retired join may still be accepted → leave
        let timer = Task { try? await Task.sleep(for: timeout); self.releaseLeaveWaiters() }
        await withCheckedContinuation { leaveWaiters.append($0) }
        timer.cancel()
    }

    /// Resume stopAndAwaitLeave callers once nothing about the old membership is still in flight.
    func releaseLeaveWaitersIfSettled() { if pendingLeaves == 0 && staleJoins == 0 { releaseLeaveWaiters() } }

    func releaseLeaveWaiters() {
        let waiters = leaveWaiters
        leaveWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func issueJoin() async throws {
        joinsOutstanding += 1
        do {
            try await service.join(Channel(id: channelID, name: channelName))
        } catch {
            joinsOutstanding -= 1
            throw error
        }
    }
}
