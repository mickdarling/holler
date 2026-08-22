import HollerCore

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
