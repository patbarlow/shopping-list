import type { Env } from "./env";

export function generateCode(): string {
  const buf = new Uint32Array(1);
  crypto.getRandomValues(buf);
  return String(buf[0]! % 1_000_000).padStart(6, "0");
}

export async function hashCode(code: string): Promise<string> {
  const data = new TextEncoder().encode(code);
  const hash = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(hash))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function sendCodeEmail(env: Env, to: string, code: string): Promise<void> {
  const from = env.RESEND_FROM ?? "Shopping List <noreply@speaking.computer>";

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from,
      to,
      subject: `Your Shopping List sign-in code: ${code}`,
      html: `
        <div style="font-family:system-ui,sans-serif;max-width:400px;margin:0 auto;padding:24px">
          <h2 style="margin:0 0 8px">Shopping List</h2>
          <p style="color:#555;margin:0 0 24px">Your sign-in code:</p>
          <div style="font-size:40px;font-weight:700;letter-spacing:8px;margin:0 0 24px">${code}</div>
          <p style="color:#888;font-size:14px;margin:0">This code expires in 10 minutes. If you didn't request this, you can safely ignore this email.</p>
        </div>
      `,
    }),
  });

  if (!res.ok) {
    const detail = await res.text();
    throw new Error(`Resend failed (${res.status}): ${detail}`);
  }
}

export function isValidEmail(raw: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(raw) && raw.length <= 320;
}
