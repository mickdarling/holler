import { describe, expect, it } from "vitest";
import { encode, MAX_FRAME_BYTES, parseMessage, type WireMessage } from "../src/protocol";

const valid: readonly WireMessage[] = [
  { hello: { participant: { id: "p1", displayName: "Mick" }, channel: "kitchen" } },
  { welcome: { participants: [{ id: "p2", displayName: "Becca" }] } },
  { welcome: { participants: [] } },
  { participantJoined: { participant: { id: "p1", displayName: "Mick" } } },
  { participantLeft: { id: "p1" } },
  { floorRequest: { from: "p1" } },
  { floorGranted: { to: "p1" } },
  { floorDenied: { to: "p1", heldBy: "p2" } },
  { floorReleased: { by: "p1" } },
  { audio: { from: "p1", frame: { sequence: 7, timestampMilliseconds: 1724190000000, payload: "AQID" } } },
  { ping: { nonce: 42 } },
  { pong: { nonce: 0 } },
  { registerPushToken: { participantId: "p1", token: "abc123" } },
];

describe("parseMessage", () => {
  it("accepts every documented message shape and round-trips through encode", () => {
    for (const message of valid) {
      expect(parseMessage(encode(message))).toEqual(message);
    }
  });

  it("accepts the exact examples from docs/wire-protocol.md", () => {
    expect(parseMessage('{"hello":{"participant":{"id":"p1","displayName":"Mick"},"channel":"kitchen"}}')).not.toBeNull();
    expect(parseMessage('{"floorDenied":{"to":"p1","heldBy":"p2"}}')).not.toBeNull();
    expect(
      parseMessage('{"audio":{"from":"p1","frame":{"sequence":7,"timestampMilliseconds":1724190000000,"payload":"AQID"}}}'),
    ).not.toBeNull();
  });

  it("rejects malformed JSON and non-object roots", () => {
    for (const text of ["", "{", "null", "42", '"ping"', "[]", '[{"ping":{"nonce":1}}]']) {
      expect(parseMessage(text)).toBeNull();
    }
  });

  it("rejects unknown case names, multiple keys, and empty objects", () => {
    expect(parseMessage('{"shout":{"from":"p1"}}')).toBeNull();
    expect(parseMessage('{"ping":{"nonce":1},"pong":{"nonce":1}}')).toBeNull();
    expect(parseMessage("{}")).toBeNull();
  });

  it("rejects extra, missing, or mistyped fields", () => {
    expect(parseMessage('{"ping":{"nonce":1,"extra":true}}')).toBeNull();
    expect(parseMessage('{"ping":{}}')).toBeNull();
    expect(parseMessage('{"ping":{"nonce":"1"}}')).toBeNull();
    expect(parseMessage('{"ping":{"nonce":-1}}')).toBeNull();
    expect(parseMessage('{"ping":{"nonce":1.5}}')).toBeNull();
    expect(parseMessage('{"ping":42}')).toBeNull();
    expect(parseMessage('{"floorRequest":{"from":""}}')).toBeNull();
    expect(parseMessage('{"floorRequest":{"to":"p1"}}')).toBeNull();
    expect(parseMessage('{"hello":{"participant":{"id":"p1"},"channel":"kitchen"}}')).toBeNull();
    expect(parseMessage('{"hello":{"participant":{"id":"p1","displayName":"M","x":1},"channel":"kitchen"}}')).toBeNull();
    expect(parseMessage('{"welcome":{"participants":[{"id":"p1"}]}}')).toBeNull();
    expect(parseMessage('{"audio":{"from":"p1","frame":{"sequence":7,"payload":"AQID"}}}')).toBeNull();
    expect(parseMessage('{"audio":{"from":"p1","frame":{"sequence":7,"timestampMilliseconds":1,"payload":3}}}')).toBeNull();
  });

  it("exposes the 16 KiB frame limit", () => {
    expect(MAX_FRAME_BYTES).toBe(16384);
  });
});
