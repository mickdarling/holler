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
        if staleJoins > 0 { staleJoins -= 1; return }  // belongs to a session that is over (answers arrive in order)
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

    /// Our own leave was confirmed: the membership it ends is already over.
    private func ownLeaveSettled() async {
        pendingLeaves -= 1
        if pendingLeaves == 0 { releaseLeaveWaiters() }
        if rejoinAfterLeave { rejoinAfterLeave = false; await rejoin() }
    }

    /// The system refused our leave: we are still a member. Stopped gate → retry the leave (bounded); running gate
    /// (a restart superseded that session) → the membership is ours again, or a refused join is retried.
    private func ownLeaveRefused() async {
        pendingLeaves -= 1
        await leaveRefused()
    }

    /// The system refused (or could not be asked) to end our membership: we are still a member.
    func leaveRefused() async {
        if !running {
            if leaveAttempts < Self.maxLeaveAttempts {
                await issueLeave()
            } else if pendingLeaves == 0 {
                releaseLeaveWaiters()  // exhausted: let a waiting stopAndAwaitLeave return
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

    /// The coordinator denied a press (someone else has the floor) while the system transmits for us: stop the system.
    func handle(notice: TalkNotice) async {
        guard case .denied = notice, systemTransmitting, joined, !stopRequested, transmitSession == channelSession
        else { return }
        await requestSystemStop()
    }

    /// Ask the system to stop our transmission once; if the command cannot even be issued, re-arm so the next state or
    /// notice asks again (no `.stopTransmitFailed` callback will come for a command that was never sent).
    private func requestSystemStop() async {
        stopRequested = true
        if (try? await service.stopTransmitting(channelID)) == nil { stopRequested = false }
    }

    /// Track the remote speaker; if the coordinator left the floor on its own (denied, disconnected) while the system
    /// still transmits for us, stop the system transmission once (the system would keep showing us talking).
    func mirror(_ state: TalkMachine.State) async {
        defer { handledStateCount += 1 }
        if case let .receiving(speaker) = state {
            receivingFrom = speaker
            pushedSpeaker = nil  // the coordinator is authoritative from here on
        } else { receivingFrom = nil }
        switch state {
        case .transmitting, .requesting: break
        case .idle, .receiving: if systemTransmitting && joined && !stopRequested { await requestSystemStop() }
        }
        refreshContinuation.yield()
    }

    func update(roster: [Participant]) {
        self.roster = roster
        refreshContinuation.yield()
    }

    /// Worker body: mirror the current speaker name into the system UI if it differs from what the system shows.
    /// Deferred while the system transmits for us (the framework rejects it then); cached only after the service
    /// accepted the update and membership did not end meanwhile, so a rejection or a leave is retried later.
    func refreshActiveSpeaker() async {
        defer { refreshCount += 1 }
        guard running, joined, !systemTransmitting else { return }
        let name = receivingFrom.map { speaker in roster.first { $0.id == speaker }?.displayName ?? speaker.rawValue }
            ?? pushedSpeaker
        guard name != activeSpeaker else { return }
        let session = channelSession, epoch = speakerEpoch
        let accepted = (try? await service.setActiveSpeaker(name, on: channelID)) != nil
        // Cache only if nothing changed the system's view meanwhile (leave, stop, or a push-delivered speaker).
        if accepted, joined, session == channelSession, epoch == speakerEpoch { activeSpeaker = name }
    }
}
