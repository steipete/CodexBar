type CodexBarJSONPrimitive = boolean | number | string | null;
type CodexBarJSONValue = CodexBarJSONPrimitive | CodexBarJSONValue[] | { [key: string]: CodexBarJSONValue };

type CodexBarEndpoint =
  | string
  | {
      setting: string;
      policy: "https" | "https-or-loopback-http";
    };

type CodexBarAuth =
  | { type: "bearer" | "x-api-key"; secret: string }
  | { type: "header"; header: string; secret: string }
  | { type: "authorization-scheme"; scheme: string; secret: string };

interface CodexBarSetting {
  key: string;
  title: string;
  subtitle?: string;
  type?: "plain" | "secure";
}

interface CodexBarRateWindow {
  usedPercent: number;
  windowMinutes?: number | null;
  resetsAt?: Date | string | null;
  resetDescription?: string | null;
  nextRegenPercent?: number | null;
}

type CodexBarNamedRateWindow = { id: string; title: string } & (CodexBarRateWindow | { window: CodexBarRateWindow });

interface CodexBarCostSnapshot {
  used: number;
  limit?: number | null;
  currency: string;
  period?: string | null;
  resetsAt?: Date | string | null;
  nextRegenAmount?: number | null;
  balance?: number | null;
}

interface CodexBarIdentitySnapshot {
  email?: string | null;
  organization?: string | null;
  loginMethod?: string | null;
  accountID?: string | null;
}

interface CodexBarDetailRow {
  label: string;
  value: string;
  secondaryValue?: string | null;
}

interface CodexBarDetailChart {
  kind: "bars" | "line";
  title?: string | null;
  unit?: string | null;
  points: Array<{ label: string; value: number }>;
}

interface CodexBarDetailSection {
  title?: string | null;
  rows: CodexBarDetailRow[];
  chart?: CodexBarDetailChart | null;
}

interface CodexBarUsageSnapshot {
  /** At least one rate window, cost, non-empty detail section, or non-empty identity field is required. */
  primary?: CodexBarRateWindow | null;
  secondary?: CodexBarRateWindow | null;
  tertiary?: CodexBarRateWindow | null;
  extraWindows?: CodexBarNamedRateWindow[] | null;
  cost?: CodexBarCostSnapshot | null;
  identity?: CodexBarIdentitySnapshot | null;
  subscriptionRenewsAt?: Date | string | null;
  subscriptionExpiresAt?: Date | string | null;
  dataConfidence?: "exact" | "estimated" | "percentOnly" | "unknown";
  details?: CodexBarDetailSection[] | null;
}

interface CodexBarHTTPRequestOptions {
  headers?: Readonly<Record<string, string>>;
  timeoutSeconds?: number;
}

interface CodexBarHTTPResponse {
  status: number;
  headers: Readonly<Record<string, string>>;
}

interface CodexBarHTTPJSONResponse<T = unknown> extends CodexBarHTTPResponse {
  json: T;
}

interface CodexBarHTTPTextResponse extends CodexBarHTTPResponse {
  bodyText: string;
}

interface CodexBarRetryOptions {
  /** Requests one delayed retry. The host clamps this interval to 10 seconds. */
  retryAfterSeconds: number;
}

interface CodexBarFailures {
  authenticationExpired(message: unknown): Error;
  missingCredential(message: unknown): Error;
  permissionDenied(message: unknown): Error;
  rateLimited(message: unknown, options?: CodexBarRetryOptions): Error;
  providerUnavailable(message: unknown, options?: CodexBarRetryOptions): Error;
  parseFailure(message: unknown): Error;
  networkFailure(message: unknown, options?: CodexBarRetryOptions): Error;
  apiFailure(message: unknown, options?: CodexBarRetryOptions): Error;
}

interface CodexBarPluginContext {
  readonly http: {
    getJSON<T = unknown>(url: string, options?: CodexBarHTTPRequestOptions): Promise<CodexBarHTTPJSONResponse<T>>;
    get(url: string, options?: CodexBarHTTPRequestOptions): Promise<CodexBarHTTPTextResponse>;
    postJSON<T = unknown>(
      url: string,
      options: CodexBarHTTPRequestOptions & { body: CodexBarJSONValue },
    ): Promise<CodexBarHTTPJSONResponse<T>>;
  };
  readonly settings: {
    get(key: string): string | null;
    getSecret(key: string): string | null;
  };
  readonly browser: {
    cookieHeader(domain: string): Promise<string>;
  };
  readonly html: {
    metaContent(html: string, name: string): string | null;
    matchFirst(html: string, regexSource: string, flags?: string): string | null;
  };
  readonly date: {
    now(): Date;
    iso(value: string): Date;
    unixSeconds(value: number): Date;
    unixMillis(value: number): Date;
    nextDailyReset(timeZone: string, hour: number): Date;
  };
  readonly format: {
    number(value: number, options?: { minimumFractionDigits?: number; maximumFractionDigits?: number }): string;
    usd(value: number): string;
    monthDay(value: Date | number | string): string;
  };
  readonly fail: Readonly<CodexBarFailures>;
  readonly env: {
    readonly timeZone: string;
  };
  readonly cache: {
    get<T = unknown>(key: string): T | undefined;
    set(key: string, value: unknown, ttlSeconds: number): void;
  };
  readonly jwt: {
    decode<T = unknown>(token: string): T;
  };
  log(...values: unknown[]): void;
  pct(used: number, limit: number): number;
  amountFromPercent(percent: number, limit: number): number;
}

interface CodexBarProviderDefinition {
  id: string;
  name: string;
  icon?: { monogram?: string; tint?: string };
  endpoints: CodexBarEndpoint[];
  auth?: CodexBarAuth;
  settings: CodexBarSetting[];
  capabilities?: Array<"browser-cookies">;
  cookieDomains?: string[];
  fetchUsage(ctx: CodexBarPluginContext): CodexBarUsageSnapshot | Promise<CodexBarUsageSnapshot>;
}

declare function defineProvider(definition: CodexBarProviderDefinition): void;
