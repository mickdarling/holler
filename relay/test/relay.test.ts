// Integration tests: real WebSockets through the Worker into the ChannelRoom Durable Object.
import { env, evictDurableObject, SELF } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { encode, parseMessage, type WireMessage } from "../src/protocol";

interface Client {
  readonly ws: WebSocket;
  readonly closed: Promise<{ code: number; reason: string }>;
  send(message: WireMessage): void;
  sendRaw(text: string): void;
  next(): Promise<WireMessage>;
  /** Resolves false if no message arrives within `ms`. */
  idle(ms?: number): Promise<boolean>;
}

const open: Client[] = [];

async function connect(channel = "kitchen"): Promise<Client> {
  const response = await SELF.fetch(`https://relay.test/v0/channels/${channel}/ws`, {
    headers: { Upgrade: "websocket" },
  });
  expect(response.status).toBe(101);
  const ws = response.webSocket;
  if (ws === null) throw new Error("no websocket");
  ws.accept();
  const queue: WireMessage[] = [];
  const waiters: Array<(m: WireMessage) => void> = [];
  ws.addEventListener("message", (event) => {
    const parsed = parseMessage(String(event.data));
    if (parsed === null) throw new Error(`relay sent malformed frame: ${String(event.data)}`);
    const waiter = waiters.shift();
    if (waiter) waiter(parsed);
    else queue.push(parsed);
  });
  const closed = new Promise<{ code: number; reason: string }>((resolve) => {
    ws.addEventListener("close", (event) => resolve({ code: event.code, reason: event.reason }));
  });
  const client: Client = {
    ws,
    closed,
    send: (m) => ws.send(encode(m)),
    sendRaw: (t) => ws.send(t),
    next: () =>
      new Promise((resolve, reject) => {
        const queued = queue.shift();
        if (queued) return resolve(queued);
        const timer = setTimeout(() => reject(new Error("timed out waiting for message")), 2000);
        waiters.push((m) => {
          clearTimeout(timer);
          resolve(m);
        });
      }),
    idle: (ms = 150) =>
      new Promise((resolve) => {
        if (queue.length > 0) return resolve(false);
        const timer = setTimeout(() => {
          const i = waiters.indexOf(waiter);
          if (i >= 0) waiters.splice(i, 1);
          resolve(true);
        }, ms);
        const waiter = (m: WireMessage): void => {
          clearTimeout(timer);
          queue.unshift(m);
          resolve(false);
        };
        waiters.push(waiter);
      }),
  };
  open.push(client);
  return client;
}

async function join(id: string, displayName = id, channel = "kitchen"): Promise<Client> {
  const c = await connect(channel);
  c.send({ hello: { participant: { id, displayName }, channel } });
  const welcome = await c.next();
  expect(welcome).toHaveProperty("welcome");
  return c;
}

afterEach(() => {
  for (const c of open.splice(0)) {
    try {
      c.ws.close(1000, "test done");
    } catch {
      // already closed
    }
  }
});

const frame = { sequence: 1, timestampMilliseconds: 1724190000000, payload: "AQID" };

describe("worker routing", () => {
  it("serves /healthz", async () => {
    const res = await SELF.fetch("https://relay.test/healthz");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });

  it("returns 404 for unknown paths and 426 without an upgrade", async () => {
    expect((await SELF.fetch("https://relay.test/nope")).status).toBe(404);
    expect((await SELF.fetch("https://relay.test/v0/channels/kitchen")).status).toBe(404);
    expect((await SELF.fetch("https://relay.test/v0/channels/kitchen/ws")).status).toBe(426);
  });
});

describe("roster", () => {
  it("welcomes with the existing roster and announces joins and leaves", async () => {
    const a = await connect();
    a.send({ hello: { participant: { id: "p1", displayName: "Mick" }, channel: "kitchen" } });
    expect(await a.next()).toEqual({ welcome: { participants: [] } });

    const b = await connect();
    b.send({ hello: { participant: { id: "p2", displayName: "Becca" }, channel: "kitchen" } });
    expect(await b.next()).toEqual({ welcome: { participants: [{ id: "p1", displayName: "Mick" }] } });
    expect(await a.next()).toEqual({ participantJoined: { participant: { id: "p2", displayName: "Becca" } } });

    b.ws.close(1000, "bye");
    expect(await a.next()).toEqual({ participantLeft: { id: "p2" } });
  });

  it("keeps channels isolated", async () => {
    const a = await join("p1");
    const b = await join("p2", "p2", "garage");
    expect(await a.idle()).toBe(true);
    expect(await b.idle()).toBe(true);
  });

  it("closes with 1008 when hello names a different channel", async () => {
    const a = await connect("kitchen");
    a.send({ hello: { participant: { id: "p1", displayName: "Mick" }, channel: "garage" } });
    expect((await a.closed).code).toBe(1008);
  });

  it("closes with 1008 for non-hello messages before hello, but answers ping", async () => {
    const a = await connect();
    a.send({ ping: { nonce: 7 } });
    expect(await a.next()).toEqual({ pong: { nonce: 7 } });
    a.send({ floorRequest: { from: "p1" } });
    expect((await a.closed).code).toBe(1008);
  });

  it("supersedes an older socket for the same participant id without a participantLeft", async () => {
    const a = await join("p1");
    const other = await join("p2");
    const a2 = await connect();
    a2.send({ hello: { participant: { id: "p1", displayName: "Mick" }, channel: "kitchen" } });
    expect(await a2.next()).toEqual({ welcome: { participants: [{ id: "p2", displayName: "p2" }] } });
    expect((await a.closed).code).toBe(4000);
    expect(await other.next()).toEqual({ participantJoined: { participant: { id: "p1", displayName: "Mick" } } });
    expect(await other.idle()).toBe(true);
  });
});

describe("floor control", () => {
  it("grants to everyone, denies others, releases, and forwards audio only from the holder", async () => {
    const a = await join("p1");
    const b = await join("p2");
    await a.next(); // participantJoined p2

    a.send({ floorRequest: { from: "p1" } });
    expect(await a.next()).toEqual({ floorGranted: { to: "p1" } });
    expect(await b.next()).toEqual({ floorGranted: { to: "p1" } });

    b.send({ floorRequest: { from: "p2" } });
    expect(await b.next()).toEqual({ floorDenied: { to: "p2", heldBy: "p1" } });
    expect(await a.idle()).toBe(true);

    b.send({ audio: { from: "p2", frame } });
    expect(await a.idle()).toBe(true);

    a.send({ audio: { from: "p1", frame } });
    expect(await b.next()).toEqual({ audio: { from: "p1", frame } });
    expect(await a.idle()).toBe(true);

    b.send({ floorReleased: { by: "p2" } });
    expect(await a.idle()).toBe(true);

    a.send({ floorReleased: { by: "p1" } });
    expect(await a.next()).toEqual({ floorReleased: { by: "p1" } });
    expect(await b.next()).toEqual({ floorReleased: { by: "p1" } });

    b.send({ floorRequest: { from: "p2" } });
    expect(await b.next()).toEqual({ floorGranted: { to: "p2" } });
    expect(await a.next()).toEqual({ floorGranted: { to: "p2" } });
  });

  it("drops spoofed sender ids", async () => {
    const a = await join("p1");
    const b = await join("p2");
    await a.next();
    a.send({ floorRequest: { from: "p2" } });
    expect(await a.idle()).toBe(true);
    expect(await b.idle()).toBe(true);
  });

  it("releases the floor then announces the leave when the holder disconnects", async () => {
    const a = await join("p1");
    const b = await join("p2");
    await a.next();
    a.send({ floorRequest: { from: "p1" } });
    await a.next();
    await b.next();
    a.ws.close(1000, "gone");
    expect(await b.next()).toEqual({ floorReleased: { by: "p1" } });
    expect(await b.next()).toEqual({ participantLeft: { id: "p1" } });
    b.send({ floorRequest: { from: "p2" } });
    expect(await b.next()).toEqual({ floorGranted: { to: "p2" } });
  });
});

describe("hibernation", () => {
  it("keeps roster and floor holder across Durable Object eviction", async () => {
    const a = await join("p1");
    const b = await join("p2");
    await a.next();
    a.send({ floorRequest: { from: "p1" } });
    await a.next();
    await b.next();

    await evictDurableObject(env.CHANNEL.get(env.CHANNEL.idFromName("kitchen")));

    // Hibernated sockets wake the object; attachment and storage are restored.
    b.send({ floorRequest: { from: "p2" } });
    expect(await b.next()).toEqual({ floorDenied: { to: "p2", heldBy: "p1" } });
    a.send({ audio: { from: "p1", frame } });
    expect(await b.next()).toEqual({ audio: { from: "p1", frame } });
    const c = await connect();
    c.send({ hello: { participant: { id: "p3", displayName: "p3" }, channel: "kitchen" } });
    const welcome = await c.next();
    expect(welcome).toHaveProperty("welcome");
    const roster = "welcome" in welcome ? welcome.welcome.participants.map((p) => p.id).sort() : [];
    expect(roster).toEqual(["p1", "p2"]);
  });
});

describe("frame validation", () => {
  it("closes with 1003 on malformed JSON", async () => {
    const a = await join("p1");
    a.sendRaw("{not json");
    expect((await a.closed).code).toBe(1003);
  });

  it("closes with 1003 on unknown message shapes", async () => {
    const a = await join("p1");
    a.sendRaw('{"floorRequest":{"from":"p1","extra":1}}');
    expect((await a.closed).code).toBe(1003);
  });

  it("closes with 1003 on frames larger than 16 KiB", async () => {
    const a = await join("p1");
    const big: WireMessage = { audio: { from: "p1", frame: { ...frame, payload: "A".repeat(16 * 1024) } } };
    a.send(big);
    expect((await a.closed).code).toBe(1003);
  });

  it("accepts registerPushToken for self and ignores it for others", async () => {
    const a = await join("p1");
    a.send({ registerPushToken: { participantId: "p1", token: "tok" } });
    a.send({ registerPushToken: { participantId: "p2", token: "tok" } });
    a.send({ ping: { nonce: 1 } });
    expect(await a.next()).toEqual({ pong: { nonce: 1 } });
  });
});
