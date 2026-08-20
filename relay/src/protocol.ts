// Wire protocol v0 types and validation. Mirrors Sources/HollerCore/WireMessage.swift
// (docs/wire-protocol.md): one JSON object per frame with exactly one key, the case
// name, whose value is an object of the labeled associated values.

export interface Participant {
  readonly id: string;
  readonly displayName: string;
}

export interface AudioFrame {
  readonly sequence: number;
  readonly timestampMilliseconds: number;
  readonly payload: string; // base64
}

export type WireMessage =
  | { readonly hello: { readonly participant: Participant; readonly channel: string } }
  | { readonly welcome: { readonly participants: readonly Participant[] } }
  | { readonly participantJoined: { readonly participant: Participant } }
  | { readonly participantLeft: { readonly id: string } }
  | { readonly floorRequest: { readonly from: string } }
  | { readonly floorGranted: { readonly to: string } }
  | { readonly floorDenied: { readonly to: string; readonly heldBy: string } }
  | { readonly floorReleased: { readonly by: string } }
  | { readonly audio: { readonly from: string; readonly frame: AudioFrame } }
  | { readonly ping: { readonly nonce: number } }
  | { readonly pong: { readonly nonce: number } }
  // Relay extension (relay/README.md): client registers an APNs device token.
  | { readonly registerPushToken: { readonly participantId: string; readonly token: string } };

/** Maximum accepted frame size in bytes (UTF-8). Larger frames close the socket with 1003. */
export const MAX_FRAME_BYTES = 16 * 1024;

type Json = Record<string, unknown>;

function isObject(value: unknown): value is Json {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Json, keys: readonly string[]): boolean {
  const own = Object.keys(value);
  return own.length === keys.length && keys.every((k) => own.includes(k));
}

function isId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

function isNonce(value: unknown): value is number {
  // Swift UInt64; JSON numbers above 2^53 are not representable here and are rejected.
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function isParticipant(value: unknown): value is Participant {
  return (
    isObject(value) &&
    hasExactKeys(value, ["id", "displayName"]) &&
    isId(value["id"]) &&
    typeof value["displayName"] === "string"
  );
}

function isAudioFrame(value: unknown): value is AudioFrame {
  return (
    isObject(value) &&
    hasExactKeys(value, ["sequence", "timestampMilliseconds", "payload"]) &&
    isNonce(value["sequence"]) &&
    isNonce(value["timestampMilliseconds"]) &&
    typeof value["payload"] === "string"
  );
}

type Validator = (body: Json) => boolean;

const validators: Readonly<Record<string, { keys: readonly string[]; check: Validator }>> = {
  hello: {
    keys: ["participant", "channel"],
    check: (b) => isParticipant(b["participant"]) && isId(b["channel"]),
  },
  welcome: {
    keys: ["participants"],
    check: (b) => Array.isArray(b["participants"]) && b["participants"].every(isParticipant),
  },
  participantJoined: { keys: ["participant"], check: (b) => isParticipant(b["participant"]) },
  participantLeft: { keys: ["id"], check: (b) => isId(b["id"]) },
  floorRequest: { keys: ["from"], check: (b) => isId(b["from"]) },
  floorGranted: { keys: ["to"], check: (b) => isId(b["to"]) },
  floorDenied: { keys: ["to", "heldBy"], check: (b) => isId(b["to"]) && isId(b["heldBy"]) },
  floorReleased: { keys: ["by"], check: (b) => isId(b["by"]) },
  audio: { keys: ["from", "frame"], check: (b) => isId(b["from"]) && isAudioFrame(b["frame"]) },
  ping: { keys: ["nonce"], check: (b) => isNonce(b["nonce"]) },
  pong: { keys: ["nonce"], check: (b) => isNonce(b["nonce"]) },
  registerPushToken: {
    keys: ["participantId", "token"],
    check: (b) => isId(b["participantId"]) && isId(b["token"]),
  },
};

/**
 * Parses one text frame. Returns null for malformed JSON, unknown case names,
 * extra or missing keys, or wrong field types.
 */
export function parseMessage(text: string): WireMessage | null {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    return null;
  }
  if (!isObject(raw)) return null;
  const keys = Object.keys(raw);
  const caseName = keys[0];
  if (keys.length !== 1 || caseName === undefined) return null;
  const spec = validators[caseName];
  const body = raw[caseName];
  if (spec === undefined || !isObject(body)) return null;
  if (!hasExactKeys(body, spec.keys) || !spec.check(body)) return null;
  return raw as WireMessage;
}

export function encode(message: WireMessage): string {
  return JSON.stringify(message);
}
