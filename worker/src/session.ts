import { SignJWT, jwtVerify } from "jose";

const SESSION_TTL = "365d";
const ISSUER = "shopping-list-api";

function secretKey(secret: string): Uint8Array {
  return new TextEncoder().encode(secret);
}

export async function issueSession(userId: string, secret: string): Promise<string> {
  return new SignJWT({ sub: userId })
    .setProtectedHeader({ alg: "HS256" })
    .setIssuedAt()
    .setIssuer(ISSUER)
    .setExpirationTime(SESSION_TTL)
    .sign(secretKey(secret));
}

export async function verifySession(token: string, secret: string): Promise<string> {
  const { payload } = await jwtVerify(token, secretKey(secret), { issuer: ISSUER });
  if (!payload.sub || typeof payload.sub !== "string") {
    throw new Error("Session token missing sub");
  }
  return payload.sub;
}
