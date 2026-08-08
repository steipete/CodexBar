(function applyProviderPluginPrelude(ctx, host) {
  "use strict";

  ctx.http = Object.freeze({
    getJSON(url, opts) {
      return new Promise((resolve, reject) => host.http(String(url), opts || {}, "GET", true, resolve, reject));
    },
    get(url, opts) {
      return new Promise((resolve, reject) => host.http(String(url), opts || {}, "GET", false, resolve, reject));
    },
    postJSON(url, opts) {
      if (!opts || typeof opts !== "object" || !("body" in opts)) {
        return Promise.reject(new TypeError("postJSON requires a body"));
      }
      let bodyJSON;
      try {
        bodyJSON = JSON.stringify(opts.body);
      } catch (error) {
        return Promise.reject(new TypeError(`postJSON body is not JSON-serializable: ${error.message}`));
      }
      if (bodyJSON === undefined) {
        return Promise.reject(new TypeError("postJSON body is not JSON-serializable"));
      }
      const hostOptions = { bodyJSON };
      if (opts.headers !== undefined) hostOptions.headers = opts.headers;
      if (opts.timeoutSeconds !== undefined) hostOptions.timeoutSeconds = opts.timeoutSeconds;
      return new Promise((resolve, reject) => host.http(String(url), hostOptions, "POST", true, resolve, reject));
    },
  });

  ctx.settings = Object.freeze({
    get(key) {
      return host.settingGet(String(key), false);
    },
    getSecret(key) {
      return host.settingGet(String(key), true);
    },
  });

  const failureKinds = Object.freeze({
    authenticationExpired: "authentication-expired",
    missingCredential: "missing-credential",
    permissionDenied: "permission-denied",
    rateLimited: "rate-limited",
    providerUnavailable: "provider-unavailable",
    parseFailure: "parse-failure",
    networkFailure: "network-failure",
    apiFailure: "api-failure",
  });
  const classifiedFailure = kind => message =>
    new Error(`__CODEXBAR_FAILURE__:${kind}:${String(message)}`);
  ctx.fail = Object.freeze(Object.fromEntries(
    Object.entries(failureKinds).map(([name, kind]) => [name, classifiedFailure(kind)])));

  ctx.browser = Object.freeze({
    cookieHeader(domain) {
      return new Promise((resolve, reject) => host.cookieHeader(String(domain), resolve, reject));
    },
  });

  ctx.html = Object.freeze({
    metaContent(html, name) {
      const target = String(name).toLowerCase();
      const tags = String(html).match(/<meta\b[^>]*>/gi) || [];
      for (const tag of tags) {
        const nameMatch = tag.match(/\b(?:name|property)\s*=\s*["']([^"']*)["']/i);
        if (!nameMatch || nameMatch[1].toLowerCase() !== target) continue;
        const contentMatch = tag.match(/\bcontent\s*=\s*["']([^"']*)["']/i);
        if (contentMatch) return contentMatch[1];
      }
      return null;
    },
    matchFirst(html, regexSource, flags) {
      const regex = new RegExp(String(regexSource), flags === undefined ? "" : String(flags));
      const match = regex.exec(String(html));
      return match ? (match.length > 1 ? match[1] : match[0]) : null;
    },
  });

  ctx.log = (...args) => host.log(args.map(value => {
    if (typeof value === "string") return value;
    try { return JSON.stringify(value); } catch (_) { return String(value); }
  }).join(" "));

  ctx.cache = Object.freeze({
    get(key) {
      return host.cacheGet(String(key));
    },
    set(key, value, ttlSeconds) {
      host.cacheSet(String(key), value, Number(ttlSeconds));
    },
  });

  function formatNumber(value, options) {
    const numeric = Number(value);
    if (!Number.isFinite(numeric)) return String(numeric);
    const settings = options || {};
    const maximum = settings.maximumFractionDigits === undefined ? 3 : Number(settings.maximumFractionDigits);
    const minimum = settings.minimumFractionDigits === undefined ? 0 : Number(settings.minimumFractionDigits);
    if (!Number.isInteger(maximum) || !Number.isInteger(minimum) || minimum < 0 || maximum < minimum || maximum > 20) {
      throw new RangeError("invalid fraction digit range");
    }
    let [integer, fraction = ""] = Math.abs(numeric).toFixed(maximum).split(".");
    while (fraction.length > minimum && fraction.endsWith("0")) fraction = fraction.slice(0, -1);
    integer = integer.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    const sign = numeric < 0 ? "-" : "";
    return `${sign}${integer}${fraction ? `.${fraction}` : ""}`;
  }

  ctx.format = Object.freeze({
    number(value, options) { return formatNumber(value, options); },
    usd(value) {
      const numeric = Number(value);
      const sign = numeric < 0 ? "-$" : "$";
      return `${sign}${formatNumber(Math.abs(numeric), { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
    },
    monthDay(value) {
      const date = value instanceof Date ? value : new Date(value);
      if (!Number.isFinite(date.getTime())) throw new TypeError("invalid date");
      const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
      return `${months[date.getMonth()]} ${date.getDate()}`;
    },
  });

  function parseDate(value) {
    const date = new Date(value);
    if (!Number.isFinite(date.getTime())) throw new TypeError("invalid date");
    return date;
  }

  function decodeBase64URL(text) {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const normalized = String(text).replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
    let bits = 0;
    let bitCount = 0;
    let output = "";
    for (const character of normalized) {
      const value = alphabet.indexOf(character);
      if (value < 0) throw new TypeError("invalid base64url data");
      bits = (bits << 6) | value;
      bitCount += 6;
      if (bitCount >= 8) {
        bitCount -= 8;
        output += String.fromCharCode((bits >> bitCount) & 0xff);
      }
    }
    let escaped = "";
    for (let index = 0; index < output.length; index += 1) {
      escaped += `%${output.charCodeAt(index).toString(16).padStart(2, "0")}`;
    }
    return decodeURIComponent(escaped);
  }

  const nowMillis = Number(ctx.__codexbarNowMillis);
  delete ctx.__codexbarNowMillis;
  ctx.date = Object.freeze({
    now() { return parseDate(nowMillis); },
    iso(value) { return parseDate(String(value)); },
    unixSeconds(value) { return parseDate(Number(value) * 1000); },
    unixMillis(value) { return parseDate(Number(value)); },
    nextDailyReset(timeZone, hour) {
      const resetHour = Number(hour);
      if (!Number.isInteger(resetHour) || resetHour < 0 || resetHour > 23) {
        throw new TypeError("reset hour must be an integer from 0 through 23");
      }
      return new Date(host.nextDailyReset(String(timeZone), resetHour));
    },
  });

  ctx.jwt = Object.freeze({
    decode(token) {
      const parts = String(token).split(".");
      if (parts.length < 2) throw new TypeError("JWT must contain a payload segment");
      return JSON.parse(decodeBase64URL(parts[1]));
    },
  });

  ctx.pct = (used, limit) => host.pct(Number(used), Number(limit));
  ctx.amountFromPercent = (percent, limit) => host.amountFromPercent(Number(percent), Number(limit));

  return ctx;
})
