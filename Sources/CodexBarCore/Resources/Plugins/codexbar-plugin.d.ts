/** A secret header bound to one declared origin; reject with its opaque ID to advance safely. */
interface CodexBarCookieSession {
  readonly id: string;
  readonly header: string;
  readonly source: string;
  readonly origin: string;
  readonly cachedAt?: number;
}

type CodexBarJSONPrimitive = boolean | number | string | null;
type CodexBarJSONValue = CodexBarJSONPrimitive | CodexBarJSONValue[] | { [key: string]: CodexBarJSONValue };

type CodexBarEndpoint =
  | string
  | {
      setting: string;
      policy: "https" | "https-or-loopback-http" | "https-or-private-network-http";
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

type CodexBarNamedRateWindow = {
  id: string;
  title: string;
  /** False keeps reset metadata visible without presenting unknown usage as a measured percentage. Defaults to true. */
  usageKnown?: boolean;
} & (CodexBarRateWindow | { window: CodexBarRateWindow });

interface CodexBarCostSnapshot {
  used: number;
  limit?: number | null;
  currency: string;
  period?: string | null;
  resetsAt?: Date | string | null;
  nextRegenAmount?: number | null;
  balance?: number | null;
}

interface CodexBarCostUsageEntry {
  date: string;
  inputTokens: number;
  outputTokens: number;
  /** Independent reported count; may exceed outputTokens and is not added to input + output totals. */
  reasoningTokens?: number | null;
  requests: number;
  cost: number;
  /** Portion of cost that is estimated rather than deducted by the provider. */
  estimatedCost?: number | null;
  model?: string | null;
}

interface CodexBarCostUsageSnapshot {
  currency: string;
  historyDays: number;
  historyLabel?: string | null;
  /** Inclusive YYYY-MM-DD end of the reported window. */
  windowEnd: string;
  entries: CodexBarCostUsageEntry[];
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
  /** Finite consumed fraction, from 0 through 1 inclusive. */
  progress?: number | null;
  /** Finite raw usage, independent of the display string and progress. */
  usageValue?: number | null;
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
  /** Explicitly declares a successful response with no displayable usage or identity. Other fields are still validated. */
  empty?: boolean;
  /** Without empty: true, at least one window, cost, non-empty detail section, or identity field is required. */
  primary?: CodexBarRateWindow | null;
  secondary?: CodexBarRateWindow | null;
  tertiary?: CodexBarRateWindow | null;
  extraWindows?: CodexBarNamedRateWindow[] | null;
  cost?: CodexBarCostSnapshot | null;
  /** Exact provider-reported daily spend. The host validates and sums every numeric row. */
  costUsage?: CodexBarCostUsageSnapshot | null;
  identity?: CodexBarIdentitySnapshot | null;
  subscriptionRenewsAt?: Date | string | null;
  subscriptionExpiresAt?: Date | string | null;
  dataConfidence?: "exact" | "estimated" | "percentOnly" | "unknown";
  details?: CodexBarDetailSection[] | null;
}

/** Result metadata is validated by the host; card and persistence require a descriptor-owned allowlist. */
interface CodexBarFetchResult {
  usage: CodexBarUsageSnapshot;
  sourceLabel?: string;
  card?: {
    openAIAPIUsage: {
      historyDays: number;
      projectID?: string | null;
      daily: Array<{
        startTime: number;
        endTime: number;
        costUSD: number;
        requests: number;
        inputTokens: number;
        cachedInputTokens: number;
        outputTokens: number;
        totalTokens: number;
        lineItems: Array<{ name: string; costUSD: number }>;
        models: Array<{
          name: string;
          requests: number;
          inputTokens: number;
          cachedInputTokens: number;
          outputTokens: number;
          totalTokens: number;
        }>;
      }>;
    };
  };
  persist?: Record<string, string>;
}

interface CodexBarHTTPRequestOptions {
  headers?: Readonly<Record<string, string>>;
  /** Hard deadline from transport start, 1–90 seconds (default 15); also bounded by the overall fetch deadline. */
  timeoutSeconds?: number;
  /** One native delayed retry for transient GET failures; POST is never retried. */
  retryPolicy?: "transientIdempotent";
}

interface CodexBarHTTPError extends Error {
  transportClass?: "timeout" | "dns" | "offline" | "cancelled" | "tls" | "connection" | "other" | "http";
  /** Foundation URLError code, preserved across both engines. */
  transportCode?: number;
  status?: number;
  /** Error-code eligibility for an idempotent retry, not a remaining retry budget. */
  retryable?: boolean;
}

interface CodexBarHTTPResponse {
  /** `http-status` exposes non-2xx responses so the plugin can take over classification from the host. */
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
  /** Requests the same one delayed retry used automatically for transient HTTP statuses; the host clamps it to 10 seconds. */
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
    /** POST a JSON body and retain the response text, including non-JSON error responses. */
    post(
      url: string,
      options: CodexBarHTTPRequestOptions & { body: CodexBarJSONValue },
    ): Promise<CodexBarHTTPTextResponse>;
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
    availability(domain: string): "available" | "off" | "manual";
    rejectCookie(domain: string, session?: CodexBarCookieSession): void;
    sessions(domain: string, options?: { cachedOnly?: boolean }): AsyncIterable<CodexBarCookieSession>;
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
    /** Native en_US currency formatting, including decimal half-even rounding and signed zero. */
    currency(value: number, currencyCode: string): string;
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
  isDetailLabel(value: unknown): boolean;
}

interface CodexBarProviderDefinition {
  id: string;
  name: string;
  icon?: { monogram?: string; tint?: string };
  /** Shows this plugin as its own provider-switcher tab. */
  topLevel?: boolean;
  endpoints: CodexBarEndpoint[];
  auth?: CodexBarAuth;
  settings: CodexBarSetting[];
  /** Grants declared browser-cookie access or lets the plugin observe and classify non-2xx HTTP responses. */
  capabilities?: Array<"browser-cookies" | "http-status">;
  cookieDomains?: string[];
  fetchUsage(
    ctx: CodexBarPluginContext,
  ): CodexBarUsageSnapshot | CodexBarFetchResult | Promise<CodexBarUsageSnapshot | CodexBarFetchResult>;
}

declare function defineProvider(definition: CodexBarProviderDefinition): void;
