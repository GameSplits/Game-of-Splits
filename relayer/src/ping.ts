// POST the low-balance alert. The URL is operator-supplied and is never logged.

export async function pingHealthcheck(url: string, fetcher: typeof fetch = fetch): Promise<void> {
  if (!url) return;
  try {
    await fetcher(url, { method: "POST", signal: AbortSignal.timeout(5_000) });
  } catch {
    // The log line is the alert. A missed ping shows up on the monitor's own grace period.
  }
}
