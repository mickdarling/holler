// One Durable Object per channel. Uses the WebSocket Hibernation API: per-socket
// participant state lives in the socket attachment and the floor holder lives in
// DO storage, so both survive eviction/hibernation.
import { DurableObject } from "cloudflare:workers";
import { createWakeSender, type WakeSender } from "./apns";
import type { RelayEnv } from "./env";
import { applyFloor, FLOOR_FREE, type FloorEffect, type FloorEvent, type FloorState } from "./floor";
import { MAX_FRAME_BYTES, parseMessage, type Participant, type WireMessage } from "./protocol";
import { channelIdFromPath, isWebSocketUpgrade } from "./routing";
import { getAttachment, type Member, membersOf, send, setAttachment } from "./socket-state";

const FLOOR_KEY = "floor";
const PUSH_PREFIX = "push:";
const CLOSE_UNSUPPORTED_DATA = 1003;
const CLOSE_POLICY_VIOLATION = 1008;
const CLOSE_SUPERSEDED = 4000;

export class ChannelRoom extends DurableObject<RelayEnv> {
  private readonly wake: WakeSender;

  constructor(ctx: DurableObjectState, env: RelayEnv) {
    super(ctx, env);
    this.wake = createWakeSender(env, (ids) => this.tokensFor(ids));
  }

  override async fetch(request: Request): Promise<Response> {
    const channel = channelIdFromPath(new URL(request.url).pathname);
    if (channel === null) return new Response("not found", { status: 404 });
    if (!isWebSocketUpgrade(request)) return new Response("expected websocket upgrade", { status: 426 });
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    this.ctx.acceptWebSocket(server);
    setAttachment(server, { channel, participant: null });
    return new Response(null, { status: 101, webSocket: client });
  }

  override async webSocketMessage(ws: WebSocket, data: string | ArrayBuffer): Promise<void> {
    if (typeof data !== "string" || new TextEncoder().encode(data).byteLength > MAX_FRAME_BYTES) {
      ws.close(CLOSE_UNSUPPORTED_DATA, "frame too large or not text");
      return;
    }
    const message = parseMessage(data);
    if (message === null) {
      ws.close(CLOSE_UNSUPPORTED_DATA, "malformed message");
      return;
    }
    const attachment = getAttachment(ws);
    if ("ping" in message) {
      send(ws, { pong: { nonce: message.ping.nonce } });
    } else if ("hello" in message) {
      await this.handleHello(ws, attachment.channel, attachment.participant, message.hello);
    } else if (attachment.participant === null) {
      ws.close(CLOSE_POLICY_VIOLATION, "hello required");
    } else {
      await this.handleMemberMessage({ ws, channel: attachment.channel, participant: attachment.participant }, message);
    }
  }

  override async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    await this.handleDisconnect(ws);
    try {
      ws.close(code, reason);
    } catch {
      // Already closed.
    }
  }

  override async webSocketError(ws: WebSocket): Promise<void> {
    await this.handleDisconnect(ws);
  }

  private async handleHello(
    ws: WebSocket,
    channel: string,
    existing: Participant | null,
    hello: { participant: Participant; channel: string },
  ): Promise<void> {
    if (hello.channel !== channel) {
      ws.close(CLOSE_POLICY_VIOLATION, "channel mismatch");
      return;
    }
    if (existing !== null) return; // A second hello on the same socket is ignored.
    const participant = hello.participant;
    for (const other of this.members()) {
      if (other.participant.id !== participant.id) continue;
      setAttachment(other.ws, { ...getAttachment(other.ws), superseded: true });
      other.ws.close(CLOSE_SUPERSEDED, "superseded by a newer connection");
    }
    setAttachment(ws, { channel, participant });
    const others = this.members().filter((m) => m.ws !== ws);
    send(ws, { welcome: { participants: others.map((m) => m.participant) } });
    for (const m of others) send(m.ws, { participantJoined: { participant } });
  }

  private async handleMemberMessage(member: Member, message: WireMessage): Promise<void> {
    const self = member.participant.id;
    if ("registerPushToken" in message) {
      if (message.registerPushToken.participantId === self) {
        await this.ctx.storage.put(PUSH_PREFIX + self, message.registerPushToken.token);
      }
      return;
    }
    // Messages must be about the sender; spoofed ids and relay-only messages are dropped.
    let event: FloorEvent | null = null;
    if ("floorRequest" in message && message.floorRequest.from === self) {
      event = { type: "request", from: self };
    } else if ("floorReleased" in message && message.floorReleased.by === self) {
      event = { type: "release", by: self };
    } else if ("audio" in message && message.audio.from === self) {
      event = { type: "audio", from: self, frame: message.audio.frame };
    }
    if (event !== null) await this.applyFloorEvent(event, member);
  }

  private async handleDisconnect(ws: WebSocket): Promise<void> {
    const attachment = getAttachment(ws);
    const participant = attachment.participant;
    if (participant === null || attachment.superseded === true) return;
    setAttachment(ws, { ...attachment, superseded: true });
    const member: Member = { ws, channel: attachment.channel, participant };
    await this.applyFloorEvent({ type: "disconnect", id: participant.id }, member);
    this.broadcast({ participantLeft: { id: participant.id } });
  }

  private async applyFloorEvent(event: FloorEvent, actor: Member): Promise<void> {
    const before = await this.floorState(actor.participant.id);
    const { state, effects } = applyFloor(before, event);
    if (state.holder !== before.holder) {
      if (state.holder === null) await this.ctx.storage.delete(FLOOR_KEY);
      else await this.ctx.storage.put(FLOOR_KEY, state.holder);
    }
    for (const effect of effects) this.runEffect(effect, actor);
  }

  private runEffect(effect: FloorEffect, actor: Member): void {
    switch (effect.kind) {
      case "broadcast":
        this.broadcast(effect.message);
        break;
      case "send":
        for (const m of this.members()) if (m.participant.id === effect.to) send(m.ws, effect.message);
        break;
      case "forward":
        for (const m of this.members()) if (m.participant.id !== effect.except) send(m.ws, effect.message);
        break;
      case "wake":
        this.ctx.waitUntil(this.wakeAbsent(actor.participant, actor.channel));
        break;
    }
  }

  /**
   * Holder from storage, treated as free if that participant is no longer connected
   * (e.g. the holder vanished while the object was evicted). The event's actor counts as
   * present: a closing socket may already be gone from getWebSockets() during webSocketClose.
   */
  private async floorState(actorId: string): Promise<FloorState> {
    const holder = await this.ctx.storage.get<string>(FLOOR_KEY);
    if (holder === undefined) return FLOOR_FREE;
    if (holder === actorId || this.members().some((m) => m.participant.id === holder)) return { holder };
    return FLOOR_FREE;
  }

  private async wakeAbsent(speaker: Participant, channel: string): Promise<void> {
    const registered = await this.ctx.storage.list<string>({ prefix: PUSH_PREFIX });
    const present = new Set(this.members().map((m) => m.participant.id));
    const absent = [...registered.keys()].map((k) => k.slice(PUSH_PREFIX.length)).filter((id) => !present.has(id));
    if (absent.length > 0) await this.wake.notify(absent, speaker, channel);
  }

  private async tokensFor(ids: readonly string[]): Promise<ReadonlyMap<string, string>> {
    const stored = await this.ctx.storage.get<string>(ids.map((id) => PUSH_PREFIX + id));
    const out = new Map<string, string>();
    for (const [key, token] of stored) out.set(key.slice(PUSH_PREFIX.length), token);
    return out;
  }

  private members(): Member[] {
    return membersOf(this.ctx.getWebSockets());
  }

  private broadcast(message: WireMessage): void {
    for (const m of this.members()) send(m.ws, message);
  }
}
