// Worker entrypoint: routes WebSocket upgrades to the per-channel Durable Object.
import type { RelayEnv } from "./env";
import { channelIdFromPath, isWebSocketUpgrade } from "./routing";

export { ChannelRoom } from "./channel-room";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

export default {
  async fetch(request: Request, env: RelayEnv): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "GET") return new Response("method not allowed", { status: 405 });
    if (url.pathname === "/healthz") return json({ ok: true });

    const channelId = channelIdFromPath(url.pathname);
    if (channelId === null) return new Response("not found", { status: 404 });
    if (!isWebSocketUpgrade(request)) {
      return new Response("expected websocket upgrade", { status: 426, headers: { upgrade: "websocket" } });
    }
    const room = env.CHANNEL.get(env.CHANNEL.idFromName(channelId));
    return room.fetch(request);
  },
} satisfies ExportedHandler<RelayEnv>;
