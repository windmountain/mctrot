// Sending email: sign-in codes, through Mailgun's HTTP API (EU region).
// Locally, without an API key, the "email" is printed to the log instead.

export type Mail = { to: string; subject: string; text: string };
export type Mailer = (mail: Mail) => Promise<void>;

export type MailgunConfig = {
  // "https://api.eu.mailgun.net" for an EU-region domain.
  baseUrl: string;
  domain: string; // the sending domain, e.g. "mg.mctrot.nyc"
  apiKey: string;
  from: string; // e.g. "McTrot <noreply@mg.mctrot.nyc>"
};

export function mailgun(config: MailgunConfig, fetchFn: typeof fetch = fetch): Mailer {
  const url = `${config.baseUrl.replace(/\/$/, "")}/v3/${config.domain}/messages`;
  const auth = `Basic ${Buffer.from(`api:${config.apiKey}`).toString("base64")}`;
  return async ({ to, subject, text }) => {
    const body = new URLSearchParams({ from: config.from, to, subject, text });
    const res = await fetchFn(url, {
      method: "POST",
      headers: { authorization: auth },
      body,
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) {
      throw new Error(`Mailgun said ${res.status}: ${(await res.text()).slice(0, 200)}`);
    }
  };
}

export function logMailer(log: (message: string) => void): Mailer {
  return async ({ to, subject, text }) => log(`[mail to ${to}] ${subject}\n${text}`);
}
