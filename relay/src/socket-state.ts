// Per-socket state for the Hibernation API. The attachment is the only per-connection
// state that survives hibernation, so everything the room needs about a socket lives here.
import { encode, type Participant, type WireMessage } from "./protocol";

interface Attachment {
  readonly channel: string;
  /** Null until the client's hello has been accepted. */
  readonly participant: Participant | null;
  /** Set once this socket has left the roster (closed, or replaced by a newer socket for the same id). */
  readonly superseded?: true;
}

export interface Member {
  readonly ws: WebSocket;
  readonly channel: string;
  readonly participant: Participant;
}

export function setAttachment(ws: WebSocket, attachment: Attachment): void {
  ws.serializeAttachment(attachment);
}

export function getAttachment(ws: WebSocket): Attachment {
  const raw: unknown = ws.deserializeAttachment();
  return isAttachment(raw) ? raw : { channel: "", participant: null };
}

function isAttachment(value: unknown): value is Attachment {
  return typeof value === "object" && value !== null && "channel" in value && "participant" in value;
}

/** Active members: sockets that completed hello and have not been superseded. */
export function membersOf(sockets: readonly WebSocket[]): Member[] {
  const out: Member[] = [];
  for (const ws of sockets) {
    const a = getAttachment(ws);
    if (a.participant !== null && a.superseded !== true) {
      out.push({ ws, channel: a.channel, participant: a.participant });
    }
  }
  return out;
}

export function send(ws: WebSocket, message: WireMessage): void {
  try {
    ws.send(encode(message));
  } catch {
    // Socket is closing; its close/error handler removes it from the roster.
  }
}
