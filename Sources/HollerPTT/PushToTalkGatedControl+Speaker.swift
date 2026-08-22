public import HollerCore

extension PushToTalkGatedControl {
    /// A leave we issued whose confirmation (`.left(.developerRequest)`) or refusal (`.leaveFailed`) is outstanding.
    /// The system processes commands in order, so the leave ends whatever membership is live once every join issued
    /// before it has been answered; its refusal means "still a member" only of such a live membership.
    struct PendingLeave {
        /// Identifies the entry its own issueLeave() appended, so the call finds it again after the command returns
        /// even though answers handled during the await may have consumed entries ahead of it.
        var id = 0
        /// Joins issued before this leave and still unanswered: they are processed first and may create the very
        /// membership this leave ends.
        var joinsAhead: Int
        /// No membership is live ahead of the remaining joins (none was confirmed when the leave was issued, or the
        /// system reported the last one ended): if every join ahead is refused, the leave targets nothing.
        var endedAhead: Bool
        /// Its membership is over (the system reported a leave of it before answering this one): a refusal now means
        /// nothing survived — nothing to reconcile to, nothing to retry.
        var invalidated = false
        /// The membership (membershipEpoch) this leave ends: the one live when it was issued, or the one the last join
        /// ahead of it created. Its confirmation ends the held membership only if that is still the current one.
        var targetEpoch = 0
    }
}

/// Pending-leave bookkeeping (same actor).
extension PushToTalkGatedControl {
    /// Ask the system to leave; the confirmation (`.left(.developerRequest)`) or refusal (`.leaveFailed`) comes later.
    /// A command that cannot even be issued is a refusal too (the membership is unchanged). `liveMembership`: the system
    /// has confirmed a membership (or that one survived) — otherwise only the joins ahead can create one.
    func issueLeave(liveMembership: Bool = true) async {
        leaveAttempts += 1
        nextLeaveID += 1
        let id = nextLeaveID
        // Before the call: its confirmation can be handled before the call returns.
        pendingLeaveQueue.append(PendingLeave(id: id, joinsAhead: joinsOutstanding + staleJoins,
                                              endedAhead: !liveMembership, targetEpoch: membershipEpoch))
        let joinsMark = joinsIssued
        let sent = (try? await service.leave(channelID)) != nil
        // A join issued while the command was in flight (an event-pump leave holds no lifecycle lock) reached the
        // system before it: the entry is re-measured as of now.
        if joinsIssued > joinsMark, let idx = pendingLeaveQueue.firstIndex(where: { $0.id == id }) {
            pendingLeaveQueue[idx].joinsAhead = joinsOutstanding + staleJoins
            pendingLeaveQueue[idx].targetEpoch = membershipEpoch
            if joined { pendingLeaveQueue[idx].endedAhead = false }
        }
        if !sent {
            // Never sent: the system owes no answer. Take our entry as it stands now (joins answered during the await
            // updated it); if an answer already consumed it, that answer settled it for us.
            guard let idx = pendingLeaveQueue.firstIndex(where: { $0.id == id }) else {
                releaseLeaveWaitersIfSettled()
                return
            }
            await leaveRefused(pendingLeaveQueue.remove(at: idx))
        }
    }

    /// The live membership is over: a pending leave with no join ahead targeted it (or an earlier one) and is void; one
    /// with joins still ahead will only end a membership those joins create.
    func liveMembershipOver() {
        for idx in pendingLeaveQueue.indices {
            if pendingLeaveQueue[idx].joinsAhead == 0 {
                pendingLeaveQueue[idx].invalidated = true
            } else {
                pendingLeaveQueue[idx].endedAhead = true
            }
        }
    }

    /// A join answered: every pending leave issued after it has one join fewer ahead. Accepted → a membership is live
    /// ahead of the leave's remaining joins; refused with none left and nothing live → the leave targets nothing.
    func joinAheadAnswered(accepted: Bool) {
        for idx in pendingLeaveQueue.indices where pendingLeaveQueue[idx].joinsAhead > 0 {
            pendingLeaveQueue[idx].joinsAhead -= 1
            if accepted {
                pendingLeaveQueue[idx].endedAhead = false
                pendingLeaveQueue[idx].targetEpoch = membershipEpoch  // the membership that join just created
            } else if pendingLeaveQueue[idx].joinsAhead == 0 && pendingLeaveQueue[idx].endedAhead {
                pendingLeaveQueue[idx].invalidated = true
            }
        }
    }
}

/// Notices, coordinator-state mirroring, and the speaker-refresh worker for PushToTalkGatedControl (same actor).
extension PushToTalkGatedControl {
    /// The coordinator denied a press (someone else has the floor) while the system transmits for us: stop the system.
    func handle(notice: TalkNotice) async {
        guard case .denied = notice, systemTransmitting, joined, !stopRequested, transmitSession == channelSession
        else { return }
        await requestSystemStop()
    }

    /// Ask the system to stop our transmission once; if the command cannot even be issued, re-arm so the next state or
    /// notice asks again (no `.stopTransmitFailed` callback will come for a command that was never sent).
    func requestSystemStop() async {
        stopRequested = true
        stopAttempts += 1
        stopGeneration = transmitGeneration
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
        joinsIssued += 1
        do {
            try await service.join(Channel(id: channelID, name: channelName))
        } catch {  // never sent, no answer will come (one join in flight at most: callers hold the lifecycle lock)
            if joinsOutstanding > 0 { joinsOutstanding -= 1 }
            throw error
        }
    }

    // MARK: TalkControlling forwarding

    public var currentRoster: [Participant] { roster }
    /// Always through the system: the coordinator's state is only observed asynchronously here, so it cannot be used
    /// to pre-empt the request. If the coordinator then denies the floor, its notice makes the gate stop the system.
    /// One begin is outstanding at most: a press while the system has not answered the last one only supersedes a
    /// release (the begin, when it lands, is pressed) — a second request would be refused as in progress, and that
    /// refusal cannot be told apart from one for the live transmission.
    public func press() async {
        guard joined else { return }
        releasePending = false  // a new press supersedes a release the begin had not caught up with
        guard !beginRequested else { return }
        if (try? await service.requestBeginTransmitting(channelID)) != nil { beginRequested = true }
    }
    /// If the stop command cannot even be issued, no end callback will come: free the coordinator ourselves (capture and
    /// the relay floor must not outlive the press); the system transmission is retried by the next state/notice. A
    /// release before the begin callback is remembered, so the begin, when it lands, is stopped rather than pressed.
    public func release() async {
        guard joined else { return }
        stopGeneration = transmitGeneration  // a refusal of this stop answers the current transmission
        let sent = (try? await service.stopTransmitting(channelID)) != nil
        if !sent {
            if systemTransmitting { await inner.release() } else if beginRequested { releasePending = true }
        }
    }
    /// A pending leave that will end the membership currently held (not one issued for an earlier membership).
    var leavePendingForCurrentMembership: Bool { pendingLeaveQueue.contains { $0.targetEpoch == membershipEpoch } }
    public nonisolated func subscribeStates() -> AsyncStream<TalkMachine.State> { inner.subscribeStates() }
    public nonisolated func subscribeNotices() -> AsyncStream<TalkNotice> { inner.subscribeNotices() }
    public nonisolated func subscribeRoster() -> AsyncStream<[Participant]> { inner.subscribeRoster() }
}
