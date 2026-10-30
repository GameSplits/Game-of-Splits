// Error text that goes to Pushover or an HTTP response must never carry an RPC URL: viem's messages include
// "URL: …" and only strip user:pass, not a key in the path (Alchemy-style /v2/KEY). Shared with keeper/src/redact.mjs.
export function redact(text, secrets = []) {
  let t = String(text ?? "");
  for (const s of secrets) if (s && s.length >= 8) t = t.split(s).join("<redacted>");
  return t.replace(/\b(?:https?|wss?):\/\/[^\s"'<>)]+/gi, "<url>");
}

/** The short, redacted text of an error: the revert name if there is one, else viem's shortMessage. */
export function errText(e, secrets = []) {
  if (e?.revert?.name) return e.revert.name;
  return redact(e?.shortMessage ?? e?.message ?? String(e), secrets).split("\n")[0].slice(0, 300);
}
