// URL routing shared by the Worker entrypoint and the Durable Object.

const CHANNEL_WS_PATH = /^\/v0\/channels\/([^/]+)\/ws$/;
const MAX_CHANNEL_ID_LENGTH = 128;

/** Returns the channel id from `/v0/channels/:channelId/ws`, or null if the path does not match. */
export function channelIdFromPath(pathname: string): string | null {
  const match = CHANNEL_WS_PATH.exec(pathname);
  const encoded = match?.[1];
  if (encoded === undefined) return null;
  let id: string;
  try {
    id = decodeURIComponent(encoded);
  } catch {
    return null;
  }
  if (id.length === 0 || id.length > MAX_CHANNEL_ID_LENGTH) return null;
  return id;
}

export function isWebSocketUpgrade(request: Request): boolean {
  return request.headers.get("Upgrade")?.toLowerCase() === "websocket";
}
