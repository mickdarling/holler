// APNs wake-up for iOS PushToTalk (docs/wire-protocol.md, "Wake-up"). Gated by
// APNS_ENABLED === "true"; otherwise a no-op sender is used.
import type { RelayEnv } from "./env";
import { importEs256PrivateKey, signEs256Jwt } from "./es256";
import type { Participant } from "./protocol";

export interface WakeSender {
  /** Notify the given (absent) participants that `speaker` holds the floor on `channel`. */
  notify(participantIds: readonly string[], speaker: Participant, channel: string): Promise<void>;
}

/** Resolves participant ids to APNs device tokens. Ids without a token are omitted. */
type TokenLookup = (participantIds: readonly string[]) => Promise<ReadonlyMap<string, string>>;

export class NoopWakeSender implements WakeSender {
  async notify(_participantIds: readonly string[], _speaker: Participant, _channel: string): Promise<void> {}
}

interface ApnsConfig {
  readonly keyId: string;
  readonly teamId: string;
  readonly privateKeyPem: string;
  readonly topic: string;
  readonly host: string;
}

const DEFAULT_HOST = "api.push.apple.com";
/** Apple accepts a provider token for up to 60 minutes; refresh well before that. */
const JWT_TTL_SECONDS = 50 * 60;

export class ApnsWakeSender implements WakeSender {
  private key: Promise<CryptoKey> | null = null;
  private cachedJwt: { token: string; issuedAt: number } | null = null;

  constructor(
    private readonly config: ApnsConfig,
    private readonly lookup: TokenLookup,
    private readonly fetchImpl: typeof fetch = fetch,
    private readonly now: () => number = () => Date.now(),
  ) {}

  async notify(participantIds: readonly string[], speaker: Participant, channel: string): Promise<void> {
    if (participantIds.length === 0) return;
    const tokens = await this.lookup(participantIds);
    if (tokens.size === 0) return;
    const jwt = await this.providerToken();
    const body = JSON.stringify({ speaker: speaker.id, speakerName: speaker.displayName, channel });
    await Promise.allSettled(
      [...tokens.values()].map((deviceToken) => this.post(deviceToken, jwt, body)),
    );
  }

  private async post(deviceToken: string, jwt: string, body: string): Promise<void> {
    const response = await this.fetchImpl(
      `https://${this.config.host}/3/device/${encodeURIComponent(deviceToken)}`,
      {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": this.config.topic,
          "apns-push-type": "pushtotalk",
          "apns-priority": "10",
          "apns-expiration": "0",
          "content-type": "application/json",
        },
        body,
      },
    );
    if (!response.ok) {
      // Body is consumed so the connection can be reused; status is logged, token is not.
      const reason = await response.text();
      console.warn(`apns push failed: ${response.status} ${reason}`);
    }
  }

  private async providerToken(): Promise<string> {
    const nowSeconds = Math.floor(this.now() / 1000);
    if (this.cachedJwt !== null && nowSeconds - this.cachedJwt.issuedAt < JWT_TTL_SECONDS) {
      return this.cachedJwt.token;
    }
    this.key ??= importEs256PrivateKey(this.config.privateKeyPem);
    const token = await signEs256Jwt(await this.key, this.config.keyId, {
      iss: this.config.teamId,
      iat: nowSeconds,
    });
    this.cachedJwt = { token, issuedAt: nowSeconds };
    return token;
  }
}

/** Reads APNs configuration from the environment; null when disabled or incomplete. */
export function apnsConfigFromEnv(env: RelayEnv): ApnsConfig | null {
  if (env.APNS_ENABLED !== "true") return null;
  const { APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY, APNS_TOPIC } = env;
  if (!APNS_KEY_ID || !APNS_TEAM_ID || !APNS_PRIVATE_KEY || !APNS_TOPIC) {
    console.warn("APNS_ENABLED is true but APNs secrets are incomplete; wake-up disabled");
    return null;
  }
  return {
    keyId: APNS_KEY_ID,
    teamId: APNS_TEAM_ID,
    privateKeyPem: APNS_PRIVATE_KEY,
    topic: APNS_TOPIC,
    host: env.APNS_HOST || DEFAULT_HOST,
  };
}

export function createWakeSender(env: RelayEnv, lookup: TokenLookup): WakeSender {
  const config = apnsConfigFromEnv(env);
  return config === null ? new NoopWakeSender() : new ApnsWakeSender(config, lookup);
}
