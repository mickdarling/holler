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
            membershipEpoch += 1  // a membership came into being, whichever join it answers
            joinAheadAnswered(accepted: true)
            await joinAnswered(accepted: true)
        case let .joinFailed(id) where id == channelID && (joinsOutstanding > 0 || staleJoins > 0):
            joinAheadAnswered(accepted: false)
            await joinAnswered(accepted: false)
        case let .left(id, .developerRequest) where id == channelID && pendingLeaves > 0: await ownLeaveSettled()
        case let .left(id, reason) where id == channelID: await membershipEnded(reason)
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
            rejoinAfterStart = false  // membership re-established by the pending join itself
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
        if terminalLeave { leaveAttempts = 0; await issueLeave(); return }  // user/app/system ended it: do not adopt
        if running || starting {
            if joinsOutstanding > 0 {
                membershipSurvived = true
            } else if pendingLeaves > 0 {
                rejoinAfterLeave = true  // our own leave (issued after that join) ends it: join again once it confirms
            } else if !joined {
                joined = true
                refreshContinuation.yield()
            }
        } else if endingSession {  // endSession() has not issued its leave yet: it will, for this membership
            membershipSurvived = true
        } else if pendingLeaves == 0 {
            leaveAttempts = 0
            await issueLeave()
        } else {
            releaseLeaveWaitersIfSettled()
        }
    }

    /// Our own leave was confirmed: the membership it ends is over, whatever latch said it survived, and the leaves
    /// queued behind it learn that just as they do from any other end of the live membership.
    private func ownLeaveSettled() async {
        let request = pendingLeaveQueue.removeFirst()
        // The leave ended the membership it targeted. If a newer one has been created since (its join accepted after
        // the leave was issued), the held membership is that newer one and untouched — including what the latches
        // (membershipSurvived, carried by endSession across its coordinator release) say about it.
        guard request.targetEpoch == membershipEpoch else {
            releaseLeaveWaitersIfSettled()
            if rejoinAfterLeave { rejoinAfterLeave = false; await rejoin() }
            return
        }
        membershipSurvived = false
        if joined {  // a membership this session adopted from a refused earlier leave: our own later leave ended it
            joined = false
            stopRequested = false
            channelSession += 1
            activeSpeaker = nil
            pushedSpeaker = nil
            speakerEpoch += 1
            if systemTransmitting { systemTransmitting = false; await inner.release() }
            if running && !terminalLeave && joinsOutstanding == 0 { rejoinAfterLeave = true }  // join again below
        }
        liveMembershipOver()
        releaseLeaveWaitersIfSettled()
        if rejoinAfterLeave { rejoinAfterLeave = false; await rejoin() }
    }

    /// The system refused our leave: we are still a member. Stopped gate → retry the leave (bounded); running gate
    /// (a restart superseded that session) → the membership is ours again, or a refused join is retried.
    private func ownLeaveRefused() async {
        await leaveRefused(pendingLeaveQueue.removeFirst())
    }

    /// The system refused (or could not be asked) to end our membership: we are still a member. During a restart the
    /// gate is not `running` yet but `starting`, and the replacement join may already be outstanding: same rules as running.
    /// After a terminal leave the membership is never adopted again: the cleanup leave is retried (bounded) instead.
    func leaveRefused(_ request: PendingLeave) async {
        if request.invalidated {  // that membership ended meanwhile: nothing survived, nothing to retry
            releaseLeaveWaitersIfSettled()
            if rejoinAfterLeave { rejoinAfterLeave = false; await rejoin() }
            return
        }
        if request.joinsAhead > 0 && request.endedAhead {  // (command never sent) nothing is live yet: the joins ahead
            releaseLeaveWaitersIfSettled()  // decide — accepted → adopted or left again; refused → never a member
            return
        }
        if terminalLeave || (!running && !starting) {
            if leaveAttempts < Self.maxLeaveAttempts {
                await issueLeave()
            } else {
                membershipSurvived = true  // exhausted: the system keeps us in; the next session end or join reconciles
                releaseLeaveWaitersIfSettled()  // let a waiting stopAndAwaitLeave return
            }
            return
        }
        rejoinAfterLeave = false  // the leave was refused: that membership stands, there is nothing to join again
        if joinsOutstanding > 0 { membershipSurvived = true; return }  // decided when that join is answered
        if !joined {  // nothing answered or pending: the system still holds our membership
            joined = true
            refreshContinuation.yield()
        }
    }

    /// The system ended our membership. Facts apply even while not running.
    private func membershipEnded(_ reason: PushToTalkLeaveReason) async {
        // Held: the system confirmed it (joined) and nothing newer was asked. The system answers a join before it can
        // report leaving that membership, so a leave while a join is unanswered (a restart or rejoin in flight) concerns
        // the membership being replaced: the standing request is not affected.
        let held = joined && joinsOutstanding == 0  // joined implies no join outstanding; guarded regardless
        joined = false
        membershipSurvived = false  // whatever membership survived a refused leave, it has ended now
        liveMembershipOver()
        stopRequested = false
        channelSession += 1
        let session = channelSession
        activeSpeaker = nil
        pushedSpeaker = nil
        speakerEpoch += 1
        if systemTransmitting {  // the system transmission ended with the membership: the coordinator must not keep
            systemTransmitting = false  // capturing and holding the relay floor
            await inner.release()
            guard session == channelSession else { return }  // a stop()/start() ran meanwhile: it owns what follows
        }
        guard reason.shouldRejoin else {
            // The user/system ending the held membership is final for the session: no rejoin until the next start(),
            // and the latches that would join again are cleared.
            if reason.isTerminal && held && (running || starting) {
                terminalLeave = true
                rejoinAfterLeave = false
                rejoinAfterAnswer = false
                rejoinAfterStart = false
            }
            return
        }
        if terminalLeave { return }  // the user/app/system ended this session's membership: no rejoin until start()
        if running { await rejoin() } else if starting { rejoinAfterStart = true }  // startup still suspended: after it
    }
    /// One rejoin per system leave event. Under the lifecycle lock so it cannot straddle a stop()/start().
    func rejoin() async {
        await acquireLifecycle()
        defer { releaseLifecycle() }
        guard running, !joined, !terminalLeave else { return }  // the user/app/system ended it: no rejoin this session
        guard joinsOutstanding == 0 else { rejoinAfterAnswer = true; return }  // a join is unanswered: retry after it
        try? await issueJoin()  // a refusal arrives as .joinFailed; nothing retries until the next start/leave
    }
}
