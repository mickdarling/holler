import { describe, expect, it } from "vitest";
import { applyFloor, FLOOR_FREE, type FloorEffect } from "../src/floor";

const frame = { sequence: 1, timestampMilliseconds: 1000, payload: "AQID" };

describe("applyFloor", () => {
  it("grants a request when the floor is free and asks to wake absent participants", () => {
    const { state, effects } = applyFloor(FLOOR_FREE, { type: "request", from: "p1" });
    expect(state).toEqual({ holder: "p1" });
    expect(effects).toEqual<FloorEffect[]>([
      { kind: "broadcast", message: { floorGranted: { to: "p1" } } },
      { kind: "wake", speaker: "p1" },
    ]);
  });

  it("denies a request while held by someone else, to the requester only", () => {
    const { state, effects } = applyFloor({ holder: "p2" }, { type: "request", from: "p1" });
    expect(state).toEqual({ holder: "p2" });
    expect(effects).toEqual<FloorEffect[]>([
      { kind: "send", to: "p1", message: { floorDenied: { to: "p1", heldBy: "p2" } } },
    ]);
  });

  it("re-acknowledges a request from the current holder without changing state", () => {
    const { state, effects } = applyFloor({ holder: "p1" }, { type: "request", from: "p1" });
    expect(state).toEqual({ holder: "p1" });
    expect(effects).toEqual<FloorEffect[]>([
      { kind: "send", to: "p1", message: { floorGranted: { to: "p1" } } },
    ]);
  });

  it("releases when the holder releases and broadcasts", () => {
    const { state, effects } = applyFloor({ holder: "p1" }, { type: "release", by: "p1" });
    expect(state).toEqual(FLOOR_FREE);
    expect(effects).toEqual<FloorEffect[]>([
      { kind: "broadcast", message: { floorReleased: { by: "p1" } } },
    ]);
  });

  it("ignores a release from a non-holder", () => {
    const { state, effects } = applyFloor({ holder: "p1" }, { type: "release", by: "p2" });
    expect(state).toEqual({ holder: "p1" });
    expect(effects).toEqual([]);
  });

  it("ignores a release when the floor is free", () => {
    expect(applyFloor(FLOOR_FREE, { type: "release", by: "p1" })).toEqual({ state: FLOOR_FREE, effects: [] });
  });

  it("forwards audio from the holder to everyone else", () => {
    const { state, effects } = applyFloor({ holder: "p1" }, { type: "audio", from: "p1", frame });
    expect(state).toEqual({ holder: "p1" });
    expect(effects).toEqual<FloorEffect[]>([
      { kind: "forward", except: "p1", message: { audio: { from: "p1", frame } } },
    ]);
  });

  it("drops audio from a non-holder and when the floor is free", () => {
    expect(applyFloor({ holder: "p1" }, { type: "audio", from: "p2", frame }).effects).toEqual([]);
    expect(applyFloor(FLOOR_FREE, { type: "audio", from: "p2", frame }).effects).toEqual([]);
  });

  it("clears the floor and broadcasts floorReleased when the holder disconnects", () => {
    const { state, effects } = applyFloor({ holder: "p1" }, { type: "disconnect", id: "p1" });
    expect(state).toEqual(FLOOR_FREE);
    expect(effects).toEqual<FloorEffect[]>([
      { kind: "broadcast", message: { floorReleased: { by: "p1" } } },
    ]);
  });

  it("does nothing when a non-holder disconnects", () => {
    expect(applyFloor({ holder: "p1" }, { type: "disconnect", id: "p2" })).toEqual({
      state: { holder: "p1" },
      effects: [],
    });
  });

  it("does not mutate the input state", () => {
    const input = { holder: null };
    applyFloor(input, { type: "request", from: "p1" });
    expect(input).toEqual({ holder: null });
  });
});
