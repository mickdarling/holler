// Floor-control state machine. Pure: no I/O, no clocks. The Durable Object
// applies the returned effects to sockets.
import type { AudioFrame, WireMessage } from "./protocol";

export interface FloorState {
  /** Participant id currently holding the floor, or null when free. */
  readonly holder: string | null;
}

export const FLOOR_FREE: FloorState = { holder: null };

export type FloorEvent =
  | { readonly type: "request"; readonly from: string }
  | { readonly type: "release"; readonly by: string }
  | { readonly type: "audio"; readonly from: string; readonly frame: AudioFrame }
  | { readonly type: "disconnect"; readonly id: string };

export type FloorEffect =
  /** Send to every participant on the channel, including the originator. */
  | { readonly kind: "broadcast"; readonly message: WireMessage }
  /** Send to one participant only. */
  | { readonly kind: "send"; readonly to: string; readonly message: WireMessage }
  /** Send to every participant except `except`. */
  | { readonly kind: "forward"; readonly except: string; readonly message: WireMessage }
  /** Wake absent participants (APNs) because `speaker` was granted the floor. */
  | { readonly kind: "wake"; readonly speaker: string };

interface FloorTransition {
  readonly state: FloorState;
  readonly effects: readonly FloorEffect[];
}

function unchanged(state: FloorState, effects: readonly FloorEffect[] = []): FloorTransition {
  return { state, effects };
}

export function applyFloor(state: FloorState, event: FloorEvent): FloorTransition {
  switch (event.type) {
    case "request": {
      if (state.holder === null) {
        return {
          state: { holder: event.from },
          effects: [
            { kind: "broadcast", message: { floorGranted: { to: event.from } } },
            { kind: "wake", speaker: event.from },
          ],
        };
      }
      if (state.holder === event.from) {
        // Idempotent re-request by the current holder: re-acknowledge, no state change.
        return unchanged(state, [
          { kind: "send", to: event.from, message: { floorGranted: { to: event.from } } },
        ]);
      }
      return unchanged(state, [
        {
          kind: "send",
          to: event.from,
          message: { floorDenied: { to: event.from, heldBy: state.holder } },
        },
      ]);
    }
    case "release": {
      if (state.holder !== event.by) return unchanged(state);
      return {
        state: FLOOR_FREE,
        effects: [{ kind: "broadcast", message: { floorReleased: { by: event.by } } }],
      };
    }
    case "audio": {
      if (state.holder !== event.from) return unchanged(state);
      return unchanged(state, [
        {
          kind: "forward",
          except: event.from,
          message: { audio: { from: event.from, frame: event.frame } },
        },
      ]);
    }
    case "disconnect": {
      if (state.holder !== event.id) return unchanged(state);
      return {
        state: FLOOR_FREE,
        effects: [{ kind: "broadcast", message: { floorReleased: { by: event.id } } }],
      };
    }
  }
}
