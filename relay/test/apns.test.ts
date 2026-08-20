import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { ApnsWakeSender, apnsConfigFromEnv, NoopWakeSender } from "../src/apns";
import { importEs256PrivateKey, pemToPkcs8, signEs256Jwt } from "../src/es256";
import type { RelayEnv } from "../src/env";

function toBase64(bytes: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(bytes)));
}

function fromBase64Url(text: string): Uint8Array {
  const b64 = text.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(text.length / 4) * 4, "=");
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
}

async function generatePem(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, [
    "sign",
    "verify",
  ])) as CryptoKeyPair;
  const der = (await crypto.subtle.exportKey("pkcs8", pair.privateKey)) as ArrayBuffer;
  const b64 = toBase64(der).replace(/(.{64})/g, "$1\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
}

const fakeEnv: RelayEnv = { ...env, APNS_ENABLED: "false" };

describe("es256", () => {
  it("parses PEM (including escaped newlines) into DER", async () => {
    const { pem } = await generatePem();
    const der = pemToPkcs8(pem);
    expect(der.byteLength).toBeGreaterThan(100);
    expect(pemToPkcs8(pem.replaceAll("\n", "\\n"))).toEqual(der);
  });

  it("produces a JWT that verifies with the matching public key", async () => {
    const { pem, publicKey } = await generatePem();
    const key = await importEs256PrivateKey(pem);
    const jwt = await signEs256Jwt(key, "KEYID", { iss: "TEAMID", iat: 1700000000 });
    const [h, p, s] = jwt.split(".");
    if (!h || !p || !s) throw new Error("bad jwt");
    expect(JSON.parse(new TextDecoder().decode(fromBase64Url(h)))).toEqual({ alg: "ES256", kid: "KEYID" });
    expect(JSON.parse(new TextDecoder().decode(fromBase64Url(p)))).toEqual({ iss: "TEAMID", iat: 1700000000 });
    const sig = fromBase64Url(s);
    expect(sig.byteLength).toBe(64);
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      sig,
      new TextEncoder().encode(`${h}.${p}`),
    );
    expect(ok).toBe(true);
  });
});

describe("apnsConfigFromEnv", () => {
  it("is null unless APNS_ENABLED is exactly 'true' with all secrets present", () => {
    expect(apnsConfigFromEnv({ ...fakeEnv, APNS_ENABLED: "false" })).toBeNull();
    expect(apnsConfigFromEnv({ ...fakeEnv, APNS_ENABLED: "true", APNS_KEY_ID: "k" })).toBeNull();
    const env: RelayEnv = {
      ...fakeEnv,
      APNS_ENABLED: "true",
      APNS_KEY_ID: "k",
      APNS_TEAM_ID: "t",
      APNS_PRIVATE_KEY: "pem",
      APNS_TOPIC: "com.example.holler.voip-ptt",
    };
    expect(apnsConfigFromEnv(env)).toEqual({
      keyId: "k",
      teamId: "t",
      privateKeyPem: "pem",
      topic: "com.example.holler.voip-ptt",
      host: "api.push.apple.com",
    });
    expect(apnsConfigFromEnv({ ...env, APNS_HOST: "api.sandbox.push.apple.com" })?.host).toBe("api.sandbox.push.apple.com");
  });
});

describe("ApnsWakeSender", () => {
  it("POSTs one pushtotalk notification per absent participant with a token", async () => {
    const { pem } = await generatePem();
    const calls: Array<{ url: string; init: RequestInit }> = [];
    const fetchImpl: typeof fetch = async (input, init) => {
      calls.push({ url: String(input), init: init ?? {} });
      return new Response("", { status: 200 });
    };
    const sender = new ApnsWakeSender(
      { keyId: "K", teamId: "T", privateKeyPem: pem, topic: "com.example.holler.voip-ptt", host: "api.push.apple.com" },
      async (ids) => new Map(ids.filter((id) => id !== "p3").map((id) => [id, `tok-${id}`])),
      fetchImpl,
      () => 1700000000000,
    );
    await sender.notify(["p2", "p3"], { id: "p1", displayName: "Mick" }, "kitchen");
    expect(calls.map((c) => c.url)).toEqual(["https://api.push.apple.com/3/device/tok-p2"]);
    const headers = new Headers(calls[0]?.init.headers);
    expect(headers.get("apns-push-type")).toBe("pushtotalk");
    expect(headers.get("apns-topic")).toBe("com.example.holler.voip-ptt");
    expect(headers.get("authorization")).toMatch(/^bearer [\w-]+\.[\w-]+\.[\w-]+$/);
    expect(JSON.parse(String(calls[0]?.init.body))).toEqual({ speaker: "p1", speakerName: "Mick", channel: "kitchen" });

    // Second call within the TTL reuses the cached provider token.
    await sender.notify(["p2"], { id: "p1", displayName: "Mick" }, "kitchen");
    expect(new Headers(calls[1]?.init.headers).get("authorization")).toBe(headers.get("authorization"));
  });

  it("does nothing with no participants and NoopWakeSender never throws", async () => {
    let called = false;
    const sender = new ApnsWakeSender(
      { keyId: "K", teamId: "T", privateKeyPem: "", topic: "t", host: "h" },
      async () => new Map(),
      async () => {
        called = true;
        return new Response();
      },
    );
    await sender.notify([], { id: "p1", displayName: "Mick" }, "kitchen");
    await sender.notify(["p2"], { id: "p1", displayName: "Mick" }, "kitchen");
    expect(called).toBe(false);
    await expect(new NoopWakeSender().notify(["p2"], { id: "p1", displayName: "Mick" }, "kitchen")).resolves.toBeUndefined();
  });
});
