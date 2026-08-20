// ES256 (ECDSA P-256 / SHA-256) JWT signing with WebCrypto. Used for APNs token auth.

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function base64UrlEncodeJson(value: unknown): string {
  return base64UrlEncode(new TextEncoder().encode(JSON.stringify(value)));
}

/** Decodes a PKCS#8 PEM (`-----BEGIN PRIVATE KEY-----`) body into DER bytes. */
export function pemToPkcs8(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem
    .replaceAll("\\n", "\n")
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export async function importEs256PrivateKey(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "pkcs8",
    pemToPkcs8(pem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

export interface Es256Claims {
  readonly iss: string;
  readonly iat: number;
}

/** Returns a compact JWS: base64url(header).base64url(claims).base64url(signature). */
export async function signEs256Jwt(
  key: CryptoKey,
  keyId: string,
  claims: Es256Claims,
): Promise<string> {
  const header = base64UrlEncodeJson({ alg: "ES256", kid: keyId });
  const payload = base64UrlEncodeJson(claims);
  const signingInput = `${header}.${payload}`;
  // WebCrypto ECDSA produces the raw r||s (64-byte) signature that JWS requires.
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  return `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
}
