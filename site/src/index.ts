const SUPPORT_EMAIL = "trolley@speaking.computer";
const LAST_UPDATED = "18 August 2026";

function page(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} — Trolley</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #ffffff;
    --fg: #1a1a1a;
    --muted: #6b6b6b;
    --accent: #1f7a5c;
    --button-bg: #1f7a5c;
    --border: #e5e5e5;
    --card: #f7f7f5;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #14150f;
      --fg: #f0efe9;
      --muted: #a2a29a;
      --accent: #6fd6ab;
      --button-bg: #1f7a5c;
      --border: #2a2b23;
      --card: #1c1d16;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--fg);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    line-height: 1.6;
  }
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    max-width: 720px;
    margin: 0 auto;
    padding: 32px 24px 0;
  }
  .brand {
    font-weight: 700;
    font-size: 18px;
    text-decoration: none;
    color: var(--fg);
    display: flex;
    align-items: center;
    gap: 8px;
  }
  .brand .dot { width: 10px; height: 10px; border-radius: 50%; background: var(--accent); }
  nav a {
    color: var(--muted);
    text-decoration: none;
    font-size: 14px;
    margin-left: 20px;
  }
  nav a:hover { color: var(--fg); }
  main {
    max-width: 720px;
    margin: 0 auto;
    padding: 40px 24px 80px;
  }
  h1 { font-size: 32px; margin: 0 0 8px; }
  h2 { font-size: 19px; margin: 32px 0 8px; }
  .updated { color: var(--muted); font-size: 14px; margin-bottom: 32px; }
  p, li { color: var(--fg); }
  ul { padding-left: 20px; }
  a { color: var(--accent); }
  .card {
    background: var(--card);
    border: 1px solid var(--border);
    border-radius: 12px;
    padding: 20px 24px;
    margin: 16px 0;
  }
  .hero {
    padding: 40px 0 20px;
  }
  .hero p { color: var(--muted); font-size: 17px; max-width: 520px; }
  .links { display: flex; gap: 12px; margin-top: 24px; flex-wrap: wrap; }
  .links a {
    display: inline-block;
    padding: 10px 18px;
    border-radius: 8px;
    border: 1px solid var(--border);
    text-decoration: none;
    color: var(--fg);
    font-size: 14px;
  }
  .links a.primary { background: var(--button-bg); border-color: var(--button-bg); color: #ffffff; font-weight: 600; }
  footer {
    max-width: 720px;
    margin: 0 auto;
    padding: 0 24px 40px;
    color: var(--muted);
    font-size: 13px;
  }
</style>
</head>
<body>
<header>
  <a class="brand" href="/"><span class="dot"></span> Trolley</a>
  <nav>
    <a href="/support">Support</a>
    <a href="/privacy">Privacy</a>
  </nav>
</header>
<main>
${body}
</main>
<footer>© 2026 <a href="https://speaking.computer">Speaking Computer</a></footer>
</body>
</html>`;
}

const home = page(
  "Home",
  `<div class="hero">
    <h1>Trolley</h1>
    <p>A shared shopping list for your household. Scan receipts, track spending, and never double up on milk again.</p>
    <div class="links">
      <a class="primary" href="/support">Support</a>
      <a href="/privacy">Privacy Policy</a>
    </div>
  </div>`,
);

const privacy = page(
  "Privacy Policy",
  `<h1>Privacy Policy</h1>
  <p class="updated">Last updated ${LAST_UPDATED}</p>

  <p>Trolley is a shopping list app for households. This page explains what data
  the app collects, why, and who it's shared with.</p>

  <h2>What we collect</h2>
  <ul>
    <li><strong>Email address</strong> — used to sign you in via a one-time code. We don't use passwords.</li>
    <li><strong>Shopping list &amp; household data</strong> — items you add, your household name, and an invite
    code used to add other members. This is visible to everyone in your household.</li>
    <li><strong>Receipts you scan</strong> — the photo (or PDF text) is sent to our AI provider to read item
    names and prices, then discarded; the extracted items, prices, and store name are saved to your household's
    account so we can show spending history and predictions.</li>
    <li><strong>Recipes you import</strong> — a photo or the URL you provide is processed the same way, to
    extract ingredients onto your list.</li>
    <li><strong>Voice input</strong> — if you add items by voice or Siri, your speech is processed by Apple's
    on-device/Siri systems to produce text; we only ever receive the resulting text.</li>
    <li><strong>Diagnostics</strong> — if the app crashes or hits an error, a crash report (device type, OS
    version, and the error itself) is sent to our error-monitoring provider so we can fix it. We don't attach
    your shopping list contents to these reports.</li>
  </ul>

  <h2>Who we share it with</h2>
  <p>We don't sell your data or use it for advertising. It's shared only with the vendors that make the app
  work, strictly to provide the service:</p>
  <ul>
    <li><strong>Anthropic</strong> — processes receipt/recipe images and text to extract items and categorise them.</li>
    <li><strong>Resend</strong> — delivers the sign-in code email.</li>
    <li><strong>Cloudflare</strong> — hosts the app's backend and database.</li>
    <li><strong>Sentry</strong> — receives crash/error diagnostics, as described above.</li>
    <li><strong>Home Assistant</strong> (optional) — if you connect your own Home Assistant instance, list
    changes are sent to the webhook URL you configure. This is off by default and entirely under your control.</li>
  </ul>

  <h2>Household sharing</h2>
  <p>Anyone who joins your household using its invite code can see and edit everything in it — the shopping
  list, receipts, spending history, and product catalogue. Only invite people you trust with that data.</p>

  <h2>Data retention &amp; deletion</h2>
  <p>Your data is kept for as long as your account exists. To delete your account and all associated data,
  email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a> and we'll remove it.</p>

  <h2>Children</h2>
  <p>Trolley is not directed at children under 13, and we don't knowingly collect data from them.</p>

  <h2>Changes to this policy</h2>
  <p>If this policy changes materially, we'll update the date at the top of this page.</p>

  <h2>Contact</h2>
  <p>Questions about this policy or your data: <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a></p>`,
);

const support = page(
  "Support",
  `<h1>Support</h1>
  <p class="updated">We're a small team — email us and we'll get back to you.</p>

  <div class="card">
    <strong>Contact</strong>
    <p style="margin-bottom:0"><a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a></p>
  </div>

  <h2>Signing in</h2>
  <p>Trolley doesn't use passwords. Enter your email, and we'll send a 6-digit code that's valid for 10
  minutes. If it doesn't arrive, check spam, or request a new one after 30 seconds.</p>

  <h2>Joining a household</h2>
  <p>Ask whoever set up your household for their invite code, and enter it in Settings → Join Household.
  Everyone in a household shares one list, one set of receipts, and one spending history.</p>

  <h2>Scanning receipts</h2>
  <p>Take a photo of a receipt (or import a PDF) and Trolley reads the items, prices, and store automatically.
  Review the results before confirming — you can fix any item it got wrong.</p>

  <h2>Something not working?</h2>
  <p>Email <a href="mailto:${SUPPORT_EMAIL}">${SUPPORT_EMAIL}</a> with what you were doing and, if you can,
  a screenshot. We read every message.</p>`,
);

export default {
  async fetch(request: Request): Promise<Response> {
    const { pathname } = new URL(request.url);
    const html =
      pathname === "/" ? home :
      pathname === "/privacy" ? privacy :
      pathname === "/support" ? support :
      null;

    if (!html) return new Response("Not found", { status: 404 });
    return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
  },
};
