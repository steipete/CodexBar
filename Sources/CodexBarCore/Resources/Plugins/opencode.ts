const OPENCODE_BASE = "https://opencode.ai";
const OPENCODE_SERVER = `${OPENCODE_BASE}/_server`;
const WORKSPACES_SERVER_ID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f";
const SUBSCRIPTION_SERVER_ID = "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4";
const BILLING_SERVER_ID = "c83b78a614689c38ebee981f9b39a8b377716db85c1fd7dbab604adc02d3313d";
const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) " +
  "Chrome/143.0.0.0 Safari/537.36";
// `auth` serves the legacy pages and server functions. The console signs requests with its own
// session cookie, so both are forwarded while workspaces migrate.
const AUTH_COOKIE_NAMES = new Set(["auth", "__Host-auth", "__Host-console_session"]);
const USD_SCALE = 100000000;

// Mirrors `OpenCodeUsageError`: only `api`/`parse` failures of the subscription call may fall back
// to billing; credential and transport failures would fail the same way there.
const INVALID = "invalid";
const API = "api";
const PARSE = "parse";
const NETWORK = "network";

interface FetchError extends Error {
  kind: string;
}

const fetchError = (kind: string, message: string): FetchError => {
  const error = new Error(message) as FetchError;
  error.name = "OpenCodeFetchError";
  error.kind = kind;
  return error;
};

const isObject = (value: unknown): value is Record<string, unknown> =>
  value !== null && typeof value === "object" && !Array.isArray(value);

const parseJSON = (text: string): unknown => {
  try {
    return JSON.parse(text);
  } catch (error) {
    void error;
    return undefined;
  }
};

// `CookieHeaderNormalizer.filteredHeader` equivalent; the broker already normalized `session.header`.
const authCookieHeader = (raw: string): string | null => {
  const kept: string[] = [];
  for (const part of raw.split(";")) {
    const trimmed = part.trim();
    const equals = trimmed.indexOf("=");
    if (equals <= 0) continue;
    const name = trimmed.slice(0, equals).trim();
    if (!name || !AUTH_COOKIE_NAMES.has(name)) continue;
    kept.push(`${name}=${trimmed.slice(equals + 1).trim()}`);
  }
  return kept.length ? kept.join("; ") : null;
};

const looksSignedOut = (text: string): boolean => {
  const lower = text.toLowerCase();
  return (
    lower.includes("login") ||
    lower.includes("sign in") ||
    lower.includes("auth/authorize") ||
    lower.includes("not associated with an account") ||
    lower.includes('actor of type "public"')
  );
};

const extractServerErrorMessage = (text: string): string | undefined => {
  const object = parseJSON(text);
  if (object === undefined) {
    const title = /<title>([^<]+)<\/title>/i.exec(text);
    return title ? title[1].trim() : undefined;
  }
  if (!isObject(object)) return undefined;
  for (const key of ["message", "error", "detail"]) {
    const value = object[key];
    if (typeof value === "string" && value.length > 0) return value;
  }
  return undefined;
};

// A server function that resolves to null answers with the seeded payload `…["server-fn:<uuid>"]=[],null)`.
const isExplicitNullPayload = (text: string): boolean => {
  const trimmed = text.trim();
  if (trimmed.toLowerCase() === "null") return true;
  if (/\]\s*=\s*\[\s*\]\s*,\s*null\s*\)\s*$/.test(trimmed)) return true;
  return parseJSON(trimmed) === null;
};

// Strict `Double(...)`/`Int(...)` parity: JSON numbers, NSNumber-bridged booleans, and decimal
// strings only; hex/whitespace-only/Infinity strings stay undefined.
const DOUBLE_PATTERN = /^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$/;
const INT_PATTERN = /^[+-]?\d+$/;

const doubleValue = (value: unknown): number | undefined => {
  if (typeof value === "boolean") return value ? 1 : 0;
  if (typeof value === "number") return Number.isFinite(value) ? value : undefined;
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!DOUBLE_PATTERN.test(trimmed)) return undefined;
    const number = Number(trimmed);
    return Number.isFinite(number) ? number : undefined;
  }
  return undefined;
};

const billingDoubleValue = (value: unknown): number | undefined => {
  if (typeof value === "boolean") return undefined;
  return doubleValue(value);
};

const intValue = (value: unknown): number | undefined => {
  if (typeof value === "boolean") return value ? 1 : 0;
  if (typeof value === "number") {
    // NSNumber.intValue truncates toward zero; out-of-range values stay undefined like Swift Int overflow.
    if (!Number.isFinite(value) || Math.abs(value) > Number.MAX_SAFE_INTEGER) return undefined;
    return Math.trunc(value);
  }
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (!INT_PATTERN.test(trimmed)) return undefined;
    const number = Number(trimmed);
    if (!Number.isInteger(number) || Math.abs(number) > Number.MAX_SAFE_INTEGER) return undefined;
    return number;
  }
  return undefined;
};

const valueForKeys = (dict: Record<string, unknown>, keys: string[]): unknown => {
  for (const key of keys) {
    if (dict[key] !== undefined) return dict[key];
  }
  return undefined;
};

const doubleForKeys = (dict: Record<string, unknown>, keys: string[]): number | undefined => {
  for (const key of keys) {
    const number = doubleValue(dict[key]);
    if (number !== undefined) return number;
  }
  return undefined;
};

const intForKeys = (dict: Record<string, unknown>, keys: string[]): number | undefined => {
  for (const key of keys) {
    const number = intValue(dict[key]);
    if (number !== undefined) return number;
  }
  return undefined;
};

const PERCENT_KEYS = [
  "usagePercent",
  "usedPercent",
  "percentUsed",
  "percent",
  "usage_percent",
  "used_percent",
  "utilization",
  "utilizationPercent",
  "utilization_percent",
  "usage",
];
const USED_KEYS = ["used", "usage", "consumed", "count", "usedTokens"];
const LIMIT_KEYS = ["limit", "total", "quota", "max", "cap", "tokenLimit"];
const RESET_IN_KEYS = [
  "resetInSec",
  "resetInSeconds",
  "resetSeconds",
  "reset_sec",
  "reset_in_sec",
  "resetsInSec",
  "resetsInSeconds",
  "resetIn",
  "resetSec",
];
const RESET_AT_KEYS = [
  "resetAt",
  "resetsAt",
  "reset_at",
  "resets_at",
  "nextReset",
  "next_reset",
  "renewAt",
  "renew_at",
];
const RENEW_AT_KEYS = ["renewAt", "renew_at"];

const dateValue = (ctx: CodexBarPluginContext, value: unknown): Date | undefined => {
  if (typeof value === "boolean") return undefined;
  if (typeof value === "number" && Number.isFinite(value)) {
    // Swift Date has no representable bound, but ctx.date throws outside the JS Date range, so an
    // absurd epoch must degrade to "no date" like the resetsAt clamp rather than an unclassified throw.
    if (value > 1e12) return value <= 8.64e15 ? ctx.date.unixMillis(value) : undefined;
    if (value > 1e9) return value <= 8.64e12 ? ctx.date.unixSeconds(value) : undefined;
    return undefined;
  }
  if (typeof value === "string") {
    const trimmed = value.trim();
    if (DOUBLE_PATTERN.test(trimmed)) return dateValue(ctx, Number(trimmed));
    try {
      return ctx.date.iso(trimmed);
    } catch (error) {
      void error;
      return undefined;
    }
  }
  return undefined;
};

// Workspace IDs are alphanumeric with optional separators; anything else is not interpolated into
// headers or request arguments.
const WORKSPACE_ID_PATTERN = /^wrk_[A-Za-z0-9_-]+$/;

const normalizeWorkspaceID = (raw: string | null): string | undefined => {
  const trimmed = (raw ?? "").trim();
  if (!trimmed) return undefined;
  if (WORKSPACE_ID_PATTERN.test(trimmed)) return trimmed;
  const pathMatch = /\/workspace\/(wrk_[A-Za-z0-9_-]+)/.exec(trimmed);
  if (pathMatch) return pathMatch[1];
  const match = /wrk_[A-Za-z0-9_-]+/.exec(trimmed);
  return match ? match[0] : undefined;
};

const parseWorkspaceIDs = (text: string): string[] => {
  const pattern = /id\s*:\s*"(wrk_[A-Za-z0-9_-]+)"/g;
  const ids: string[] = [];
  let match;
  while ((match = pattern.exec(text)) !== null) ids.push(match[1]);
  return ids;
};

const parseWorkspaceIDsFromJSON = (text: string): string[] => {
  const object = parseJSON(text);
  if (object === undefined) return [];
  const results: string[] = [];
  const collect = (value: unknown): void => {
    if (isObject(value)) {
      for (const key of Object.keys(value)) collect(value[key]);
      return;
    }
    if (Array.isArray(value)) {
      for (const item of value) collect(item);
      return;
    }
    if (typeof value === "string" && WORKSPACE_ID_PATTERN.test(value) && !results.includes(value)) {
      results.push(value);
    }
  };
  collect(object);
  return results;
};

interface ParsedWindow {
  percent: number;
  resetInSec: number;
}

const parseWindow = (ctx: CodexBarPluginContext, dict: Record<string, unknown>, now: Date): ParsedWindow | null => {
  let percent = doubleForKeys(dict, PERCENT_KEYS);
  // A direct percent field may arrive as a fraction (0...1) or a percent (0...100), so it goes
  // through the `<= 1` heuristic below. A computed used/limit percent is already 0...100 and must not.
  const percentIsDirect = percent !== undefined;
  if (percent === undefined) {
    const used = doubleForKeys(dict, USED_KEYS);
    const limit = doubleForKeys(dict, LIMIT_KEYS);
    if (used !== undefined && limit !== undefined && limit > 0) percent = (used / limit) * 100;
  }
  if (percent === undefined) return null;
  if (percentIsDirect && percent <= 1 && percent >= 0) percent *= 100;
  percent = Math.max(0, Math.min(100, percent));

  let resetInSec = intForKeys(dict, RESET_IN_KEYS);
  if (resetInSec === undefined) {
    const resetAt = dateValue(ctx, valueForKeys(dict, RESET_AT_KEYS));
    if (resetAt) {
      const interval = (resetAt.getTime() - now.getTime()) / 1000;
      if (Number.isFinite(interval) && interval <= Number.MAX_SAFE_INTEGER) {
        resetInSec = interval <= 0 ? 0 : Math.trunc(interval);
      }
    }
  }
  return { percent, resetInSec: Math.max(0, resetInSec ?? 0) };
};

interface WindowCandidate {
  id: number;
  percent: number;
  resetInSec: number;
  pathLower: string;
}

const collectWindowCandidates = (ctx: CodexBarPluginContext, object: unknown, now: Date): WindowCandidate[] => {
  const candidates: WindowCandidate[] = [];
  const visit = (value: unknown, path: string[]): void => {
    if (isObject(value)) {
      const window = parseWindow(ctx, value, now);
      if (window) {
        candidates.push({
          id: candidates.length,
          percent: window.percent,
          resetInSec: window.resetInSec,
          pathLower: path.join(".").toLowerCase(),
        });
      }
      for (const key of Object.keys(value)) visit(value[key], [...path, key]);
      return;
    }
    if (Array.isArray(value)) {
      value.forEach((item, index) => visit(item, [...path, `[${index}]`]));
    }
  };
  visit(object, []);
  return candidates;
};

const pickCandidateFrom = (candidates: WindowCandidate[], pickShorter: boolean): WindowCandidate | undefined => {
  let best: WindowCandidate | undefined;
  for (const candidate of candidates) {
    if (
      best === undefined ||
      (candidate.resetInSec === best.resetInSec
        ? candidate.percent > best.percent
        : pickShorter
          ? candidate.resetInSec < best.resetInSec
          : candidate.resetInSec > best.resetInSec)
    ) {
      best = candidate;
    }
  }
  return best;
};

const pickCandidate = (
  preferred: WindowCandidate[],
  fallback: WindowCandidate[],
  pickShorter: boolean,
  excluding?: number,
): WindowCandidate | undefined =>
  pickCandidateFrom(
    preferred.filter((candidate) => candidate.id !== excluding),
    pickShorter,
  ) ??
  pickCandidateFrom(
    fallback.filter((candidate) => candidate.id !== excluding),
    pickShorter,
  );

interface ParsedSubscription {
  rollingUsagePercent: number;
  weeklyUsagePercent: number;
  rollingResetInSec: number;
  weeklyResetInSec: number;
  renewsAt?: Date;
}

const buildSnapshot = (
  ctx: CodexBarPluginContext,
  rolling: Record<string, unknown>,
  weekly: Record<string, unknown>,
  now: Date,
  renewsAt: Date | undefined,
): ParsedSubscription | null => {
  const rollingWindow = parseWindow(ctx, rolling, now);
  const weeklyWindow = parseWindow(ctx, weekly, now);
  if (!rollingWindow || !weeklyWindow) return null;
  return {
    rollingUsagePercent: rollingWindow.percent,
    weeklyUsagePercent: weeklyWindow.percent,
    rollingResetInSec: rollingWindow.resetInSec,
    weeklyResetInSec: weeklyWindow.resetInSec,
    renewsAt,
  };
};

const ROLLING_KEYS = ["rollingUsage", "rolling", "rolling_usage", "rollingWindow", "rolling_window"];
const WEEKLY_KEYS = ["weeklyUsage", "weekly", "weekly_usage", "weeklyWindow", "weekly_window"];

const parseUsageDictionary = (
  ctx: CodexBarPluginContext,
  dict: Record<string, unknown>,
  now: Date,
  inheritedRenewsAt: Date | undefined,
): ParsedSubscription | null => {
  const renewsAt = dateValue(ctx, valueForKeys(dict, RENEW_AT_KEYS)) ?? inheritedRenewsAt;
  const usage = dict["usage"];
  if (isObject(usage)) {
    const snapshot = parseUsageDictionary(ctx, usage, now, renewsAt);
    if (snapshot) return snapshot;
  }
  const rolling = ROLLING_KEYS.map((key) => dict[key]).find(isObject);
  const weekly = WEEKLY_KEYS.map((key) => dict[key]).find(isObject);
  if (rolling && weekly) return buildSnapshot(ctx, rolling, weekly, now, renewsAt);
  return null;
};

const parseUsageNested = (
  ctx: CodexBarPluginContext,
  dict: Record<string, unknown>,
  now: Date,
  depth: number,
  inheritedRenewsAt: Date | undefined,
): ParsedSubscription | null => {
  if (depth > 3) return null;
  const renewsAt = dateValue(ctx, valueForKeys(dict, RENEW_AT_KEYS)) ?? inheritedRenewsAt;
  let rolling: Record<string, unknown> | undefined;
  let weekly: Record<string, unknown> | undefined;
  for (const key of Object.keys(dict)) {
    const sub = dict[key];
    if (!isObject(sub)) continue;
    const lower = key.toLowerCase();
    if (lower.includes("rolling")) {
      rolling = sub;
    } else if (lower.includes("weekly") || lower.includes("week")) {
      weekly = sub;
    }
  }
  if (rolling && weekly) {
    const snapshot = buildSnapshot(ctx, rolling, weekly, now, renewsAt);
    if (snapshot) return snapshot;
  }
  for (const key of Object.keys(dict)) {
    const sub = dict[key];
    if (!isObject(sub)) continue;
    const snapshot = parseUsageNested(ctx, sub, now, depth + 1, renewsAt);
    if (snapshot) return snapshot;
  }
  return null;
};

const parseUsageFromCandidates = (
  ctx: CodexBarPluginContext,
  object: unknown,
  now: Date,
  inheritedRenewsAt?: Date,
): ParsedSubscription | null => {
  const candidates = collectWindowCandidates(ctx, object, now);
  if (candidates.length === 0) return null;
  const rollingCandidates = candidates.filter(
    (candidate) =>
      candidate.pathLower.includes("rolling") ||
      candidate.pathLower.includes("hour") ||
      candidate.pathLower.includes("5h") ||
      candidate.pathLower.includes("5-hour"),
  );
  const weeklyCandidates = candidates.filter(
    (candidate) => candidate.pathLower.includes("weekly") || candidate.pathLower.includes("week"),
  );
  const rolling = pickCandidate(rollingCandidates, candidates, true);
  const weekly = pickCandidate(weeklyCandidates, candidates, false, rolling?.id);
  if (!rolling || !weekly) return null;
  const renewsAt =
    (isObject(object) ? dateValue(ctx, valueForKeys(object, RENEW_AT_KEYS)) : undefined) ?? inheritedRenewsAt;
  return {
    rollingUsagePercent: rolling.percent,
    weeklyUsagePercent: weekly.percent,
    rollingResetInSec: rolling.resetInSec,
    weeklyResetInSec: weekly.resetInSec,
    renewsAt,
  };
};

const parseUsageJSON = (ctx: CodexBarPluginContext, object: unknown, now: Date): ParsedSubscription | null => {
  if (!isObject(object)) return null;
  const renewsAt = dateValue(ctx, valueForKeys(object, RENEW_AT_KEYS));
  const direct = parseUsageDictionary(ctx, object, now, renewsAt);
  if (direct) return direct;
  for (const key of ["data", "result", "usage", "billing", "payload"]) {
    const nested = object[key];
    if (!isObject(nested)) continue;
    const snapshot = parseUsageDictionary(ctx, nested, now, renewsAt);
    if (snapshot) return snapshot;
  }
  const nested = parseUsageNested(ctx, object, now, 0, renewsAt);
  if (nested) return nested;
  return parseUsageFromCandidates(ctx, object, now, renewsAt);
};

const parseSubscriptionJSON = (ctx: CodexBarPluginContext, text: string, now: Date): ParsedSubscription | null => {
  const object = parseJSON(text);
  if (object === undefined) return null;
  const snapshot = parseUsageJSON(ctx, object, now);
  if (snapshot) return snapshot;
  return parseUsageFromCandidates(ctx, object, now);
};

const extractDouble = (pattern: string, text: string): number | undefined => {
  const match = new RegExp(pattern).exec(text);
  if (!match) return undefined;
  const number = Number(match[1]);
  return Number.isFinite(number) ? number : undefined;
};

const extractInt = (pattern: string, text: string): number | undefined => {
  const match = new RegExp(pattern).exec(text);
  if (!match) return undefined;
  const number = Number(match[1]);
  return Number.isInteger(number) ? number : undefined;
};

const parseSubscription = (ctx: CodexBarPluginContext, text: string, now: Date): ParsedSubscription => {
  const json = parseSubscriptionJSON(ctx, text, now);
  if (json) return json;
  const rollingPercent = extractDouble("rollingUsage[^}]*?usagePercent\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)", text);
  const rollingReset = extractInt("rollingUsage[^}]*?resetInSec\\s*:\\s*([0-9]+)", text);
  const weeklyPercent = extractDouble("weeklyUsage[^}]*?usagePercent\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)", text);
  const weeklyReset = extractInt("weeklyUsage[^}]*?resetInSec\\s*:\\s*([0-9]+)", text);
  if (
    rollingPercent === undefined ||
    rollingReset === undefined ||
    weeklyPercent === undefined ||
    weeklyReset === undefined
  ) {
    throw fetchError(PARSE, "Missing usage fields.");
  }
  return {
    rollingUsagePercent: rollingPercent,
    weeklyUsagePercent: weeklyPercent,
    rollingResetInSec: rollingReset,
    weeklyResetInSec: weeklyReset,
  };
};

// opencode.ai reports `balance` and `monthlyUsage` as fixed-point integers scaled by 1e8, while
// `monthlyLimit`/`reloadAmount`/`reloadTrigger` are already whole USD.
interface ParsedBilling {
  monthlyUsageUSD: number;
  monthlyLimitUSD?: number;
  balanceUSD?: number;
  hasSubscription: boolean;
}

const findCustomerDictionary = (object: unknown): Record<string, unknown> | undefined => {
  if (isObject(object)) {
    const customerID = object["customerID"];
    if (typeof customerID === "string" && customerID.length > 0) return object;
    for (const key of Object.keys(object)) {
      const found = findCustomerDictionary(object[key]);
      if (found) return found;
    }
    return undefined;
  }
  if (Array.isArray(object)) {
    for (const item of object) {
      const found = findCustomerDictionary(item);
      if (found) return found;
    }
  }
  return undefined;
};

// Matches both JSON (`"balance": 1`) and the `$R[...]` payload (`balance:$R[3]=1`).
const fieldPattern = (field: string, value: string): RegExp =>
  new RegExp(`(?:"${field}"|${field})\\s*:\\s*(?:\\$R\\[\\d+\\]\\s*=\\s*)?${value}`);

const billingFieldNumber = (field: string, text: string): number | undefined => {
  const match = fieldPattern(field, "(-?[0-9]+(?:\\.[0-9]+)?)").exec(text);
  if (!match) return undefined;
  const number = Number(match[1]);
  return Number.isFinite(number) ? number : undefined;
};

const hasSubscriptionObject = (text: string): boolean => {
  if (!fieldPattern("subscription", "[^,}]+").test(text)) return false;
  return !fieldPattern("subscription", "null").test(text);
};

const parseBillingJSON = (text: string): ParsedBilling | undefined => {
  const object = parseJSON(text);
  if (object === undefined) return undefined;
  const customer = findCustomerDictionary(object);
  if (!customer) return undefined;
  const rawUsage = billingDoubleValue(customer["monthlyUsage"]);
  if (rawUsage === undefined) return undefined;
  const balance = billingDoubleValue(customer["balance"]);
  return {
    monthlyUsageUSD: rawUsage / USD_SCALE,
    monthlyLimitUSD: billingDoubleValue(customer["monthlyLimit"]),
    balanceUSD: balance === undefined ? undefined : balance / USD_SCALE,
    hasSubscription: customer["subscription"] !== undefined && customer["subscription"] !== null,
  };
};

const parseBillingPayload = (text: string): ParsedBilling | undefined => {
  if (!fieldPattern("customerID", '\\"[^\\"]+\\"').test(text)) return undefined;
  const rawUsage = billingFieldNumber("monthlyUsage", text);
  if (rawUsage === undefined) return undefined;
  const balance = billingFieldNumber("balance", text);
  return {
    monthlyUsageUSD: rawUsage / USD_SCALE,
    monthlyLimitUSD: billingFieldNumber("monthlyLimit", text),
    balanceUSD: balance === undefined ? undefined : balance / USD_SCALE,
    hasSubscription: hasSubscriptionObject(text),
  };
};

const parseBilling = (text: string): ParsedBilling | undefined => parseBillingJSON(text) ?? parseBillingPayload(text);

interface ServerRequest {
  serverID: string;
  args?: CodexBarJSONValue[];
  method: "GET" | "POST";
  referer: string;
}

const serverRequestURL = (request: ServerRequest): string => {
  if (request.method !== "GET") return OPENCODE_SERVER;
  let url = `${OPENCODE_SERVER}?id=${encodeURIComponent(request.serverID)}`;
  if (request.args !== undefined && request.args.length > 0) {
    url += `&args=${encodeURIComponent(JSON.stringify(request.args))}`;
  }
  return url;
};

let serverInstanceCounter = 0;
const nextServerInstance = (): string => `server-fn:${(serverInstanceCounter += 1)}-${Date.now().toString(36)}`;

const fetchServerText = async (
  ctx: CodexBarPluginContext,
  request: ServerRequest,
  cookieHeader: string,
): Promise<string> => {
  const headers: Record<string, string> = {
    Cookie: cookieHeader,
    "X-Server-Id": request.serverID,
    "X-Server-Instance": nextServerInstance(),
    "User-Agent": USER_AGENT,
    Origin: OPENCODE_BASE,
    Referer: request.referer,
    Accept: "text/javascript, application/json;q=0.9, */*;q=0.8",
  };
  const url = serverRequestURL(request);
  let response: CodexBarHTTPTextResponse;
  const timeoutSeconds = Number(ctx.settings.get("REQUEST_TIMEOUT") || 15);
  try {
    response =
      request.method === "GET"
        ? await ctx.http.get(url, { headers, timeoutSeconds })
        : await ctx.http.post(url, { headers, timeoutSeconds, body: request.args ?? [] });
  } catch (error) {
    const transport = error as CodexBarHTTPError;
    if (transport.transportClass === "cancelled") throw error;
    throw fetchError(NETWORK, `OpenCode network error: ${transport.message ?? "request failed"}`);
  }
  const bodyText = response.bodyText ?? "";
  if (response.status === 200) return bodyText;
  if (looksSignedOut(bodyText) || response.status === 401 || response.status === 403) {
    throw fetchError(INVALID, "OpenCode session cookie is invalid or expired.");
  }
  const message = extractServerErrorMessage(bodyText);
  throw fetchError(API, message ? `HTTP ${response.status}: ${message}` : `HTTP ${response.status}`);
};

const fetchWorkspaceID = async (ctx: CodexBarPluginContext, cookieHeader: string): Promise<string> => {
  const text = await fetchServerText(
    ctx,
    { serverID: WORKSPACES_SERVER_ID, method: "GET", referer: OPENCODE_BASE },
    cookieHeader,
  );
  if (looksSignedOut(text)) {
    throw fetchError(INVALID, "OpenCode session cookie is invalid or expired.");
  }
  let ids = parseWorkspaceIDs(text);
  if (ids.length === 0) ids = parseWorkspaceIDsFromJSON(text);
  if (ids.length === 0) {
    // Some SolidStart responses omit the workspace listing on GET; POST answers with the array.
    const fallback = await fetchServerText(
      ctx,
      { serverID: WORKSPACES_SERVER_ID, args: [], method: "POST", referer: OPENCODE_BASE },
      cookieHeader,
    );
    if (looksSignedOut(fallback)) {
      throw fetchError(INVALID, "OpenCode session cookie is invalid or expired.");
    }
    ids = parseWorkspaceIDs(fallback);
    if (ids.length === 0) ids = parseWorkspaceIDsFromJSON(fallback);
    if (ids.length === 0) throw fetchError(PARSE, "Missing workspace id.");
    return ids[0];
  }
  return ids[0];
};

const missingSubscriptionDataError = (workspaceID: string): FetchError =>
  fetchError(
    API,
    `No subscription usage data was returned for workspace ${workspaceID}. ` +
      "This usually means this workspace does not have OpenCode subscription quota data available.",
  );

const fetchSubscriptionInfo = async (
  ctx: CodexBarPluginContext,
  workspaceID: string,
  cookieHeader: string,
  now: Date,
): Promise<string> => {
  const referer = `${OPENCODE_BASE}/workspace/${workspaceID}/billing`;
  const text = await fetchServerText(
    ctx,
    { serverID: SUBSCRIPTION_SERVER_ID, args: [workspaceID], method: "GET", referer },
    cookieHeader,
  );
  if (looksSignedOut(text)) {
    throw fetchError(INVALID, "OpenCode session cookie is invalid or expired.");
  }
  if (isExplicitNullPayload(text)) throw missingSubscriptionDataError(workspaceID);
  const json = parseSubscriptionJSON(ctx, text, now);
  const rollingRegex =
    extractDouble("rollingUsage[^}]*?usagePercent\\s*:\\s*([0-9]+(?:\\.[0-9]+)?)", text) !== undefined;
  if (!json && !rollingRegex) {
    const fallback = await fetchServerText(
      ctx,
      { serverID: SUBSCRIPTION_SERVER_ID, args: [workspaceID], method: "POST", referer },
      cookieHeader,
    );
    if (looksSignedOut(fallback)) {
      throw fetchError(INVALID, "OpenCode session cookie is invalid or expired.");
    }
    if (isExplicitNullPayload(fallback)) throw missingSubscriptionDataError(workspaceID);
    return fallback;
  }
  return text;
};

// Pay-as-you-go workspaces have no subscription object, so the subscription server function answers
// with null or fails outright. Their spend lives in the billing payload instead, which is still
// reachable with the same session cookie.
const fetchPayAsYouGoUsage = async (
  ctx: CodexBarPluginContext,
  workspaceID: string,
  cookieHeader: string,
): Promise<CodexBarUsageSnapshot | null> => {
  const text = await fetchServerText(
    ctx,
    {
      serverID: BILLING_SERVER_ID,
      args: [workspaceID],
      method: "GET",
      referer: `${OPENCODE_BASE}/workspace/${workspaceID}`,
    },
    cookieHeader,
  );
  if (looksSignedOut(text)) {
    throw fetchError(INVALID, "OpenCode session cookie is invalid or expired.");
  }
  const billing = parseBilling(text);
  if (!billing || billing.hasSubscription) return null;
  // The billing payload carries no cycle boundary, so `resetsAt` stays unset rather than guessing
  // one. A workspace with no configured limit reports `limit: 0`, the same convention the OpenAI and
  // ClawRouter providers use for limitless spend.
  const primary =
    billing.monthlyLimitUSD !== undefined && billing.monthlyLimitUSD > 0
      ? {
          usedPercent: Math.min(100, Math.max(0, (billing.monthlyUsageUSD / billing.monthlyLimitUSD) * 100)),
          windowMinutes: 30 * 24 * 60,
        }
      : null;
  return {
    primary,
    cost: {
      used: billing.monthlyUsageUSD,
      limit: billing.monthlyLimitUSD ?? 0,
      currency: "USD",
      period: "Monthly",
      balance: billing.balanceUSD ?? null,
    },
  };
};

const fetchUsageForSession = async (
  ctx: CodexBarPluginContext,
  cookieHeader: string,
  workspaceIDOverride: string | undefined,
): Promise<CodexBarUsageSnapshot> => {
  const now = ctx.date.now();
  const workspaceID = workspaceIDOverride ?? (await fetchWorkspaceID(ctx, cookieHeader));
  try {
    const text = await fetchSubscriptionInfo(ctx, workspaceID, cookieHeader, now);
    const subscription = parseSubscription(ctx, text, now);
    const resetsAt = (seconds: number): Date | undefined => {
      const time = now.getTime() + seconds * 1000;
      // JavaScript Date is capped near 8.64e15 ms; Swift clamps instead, so an absurd reset interval
      // must not turn a valid payload into an invalid snapshot.
      return Number.isFinite(time) && Math.abs(time) <= 8.64e15 ? new Date(time) : undefined;
    };
    const snapshot: CodexBarUsageSnapshot = {
      primary: {
        usedPercent: subscription.rollingUsagePercent,
        windowMinutes: 5 * 60,
        resetsAt: resetsAt(subscription.rollingResetInSec),
      },
      secondary: {
        usedPercent: subscription.weeklyUsagePercent,
        windowMinutes: 7 * 24 * 60,
        resetsAt: resetsAt(subscription.weeklyResetInSec),
      },
    };
    if (subscription.renewsAt) {
      snapshot.extraWindows = [
        {
          id: "renewal",
          title: "Renews",
          window: { usedPercent: 0, resetsAt: subscription.renewsAt },
        },
      ];
    }
    return snapshot;
  } catch (error) {
    const failure = error as FetchError;
    if (failure.kind !== API && failure.kind !== PARSE) throw error;
    // Pay-as-you-go workspaces answer the billing server function even when subscription is absent.
    try {
      const payg = await fetchPayAsYouGoUsage(ctx, workspaceID, cookieHeader);
      if (payg) return payg;
    } catch (billingError) {
      if ((billingError as FetchError).kind === INVALID) throw billingError;
      if ((billingError as CodexBarHTTPError).transportClass === "cancelled") throw billingError;
      ctx.log(`OpenCode billing fallback failed: ${(billingError as Error).message ?? billingError}`);
    }
    throw error;
  }
};

const classify = (ctx: CodexBarPluginContext, error: unknown): Error => {
  const failure = error as FetchError;
  switch (failure.kind) {
    case INVALID:
      return ctx.fail.authenticationExpired(failure.message);
    case NETWORK:
      return ctx.fail.networkFailure(failure.message);
    case PARSE:
      return ctx.fail.parseFailure(failure.message);
    case API:
      return ctx.fail.apiFailure(failure.message);
    default:
      return error instanceof Error ? error : new Error(String(error));
  }
};

defineProvider({
  id: "opencode",
  name: "OpenCode",
  endpoints: [OPENCODE_BASE],
  settings: [
    { key: "WORKSPACE_ID", title: "OpenCode workspace ID", type: "plain" },
    { key: "REQUEST_TIMEOUT", title: "Request timeout", type: "plain" },
  ],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["opencode.ai", "app.opencode.ai"],
  async fetchUsage(ctx) {
    const policy = ctx.browser.availability("opencode.ai");
    if (policy === "off") throw ctx.fail.missingCredential("OpenCode browser cookies are disabled.");
    const manual = policy === "manual";
    const workspaceOverride = normalizeWorkspaceID(ctx.settings.get("WORKSPACE_ID"));

    // opencode.ai carries `auth`/`__Host-auth` for the server functions; app.opencode.ai carries the
    // migrated console session. Either cookie authenticates, so each domain's session is tried on its
    // own, primary first and the console domain only when the primary is exhausted. Unlike the native
    // importer, which merges both domains into one header, the broker binds each session to its own
    // domain (the same per-domain scoping qoder.js uses).
    let rejected = false;
    let terminalError: unknown;
    for (const domain of ["opencode.ai", "app.opencode.ai"]) {
      for await (const session of ctx.browser.sessions(domain)) {
        const cookieHeader = authCookieHeader(session.header);
        // Sources without an auth-family cookie are skipped, matching the importer's gate.
        if (!cookieHeader) continue;
        try {
          return await fetchUsageForSession(ctx, cookieHeader, workspaceOverride);
        } catch (error) {
          const failure = error as FetchError;
          if (failure.kind === INVALID) {
            rejected = true;
            ctx.browser.rejectCookie(domain, session);
            if (manual) throw ctx.fail.authenticationExpired(failure.message);
            continue;
          }
          if ((error as CodexBarHTTPError).transportClass === "cancelled") throw error;
          terminalError = error;
        }
      }
    }
    if (terminalError !== undefined) throw classify(ctx, terminalError);
    if (rejected) {
      throw ctx.fail.authenticationExpired("OpenCode session cookie is invalid or expired.");
    }
    if (manual) throw ctx.fail.missingCredential("OpenCode cookie header is invalid.");
    throw ctx.fail.missingCredential(
      "No OpenCode session cookies found in browsers. Sign in to opencode.ai in Chrome, or paste a Cookie header.",
    );
  },
});
