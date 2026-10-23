function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}
function _optionalChain(ops) {
  let lastAccessLHS = undefined;
  let value = ops[0];
  let i = 1;
  while (i < ops.length) {
    const op = ops[i];
    const fn = ops[i + 1];
    i += 2;
    if ((op === "optionalAccess" || op === "optionalCall") && value == null) {
      return undefined;
    }
    if (op === "access" || op === "optionalAccess") {
      lastAccessLHS = value;
      value = fn(value);
    } else if (op === "call" || op === "optionalCall") {
      value = fn((...args) => value.call(lastAccessLHS, ...args));
      lastAccessLHS = undefined;
    }
  }
  return value;
}
defineProvider({
  id: "chatbox",
  name: "Chatbox AI",
  endpoints: ["https://api.chatboxai.app"],
  auth: { type: "header", header: "Authorization", secret: "CHATBOX_LICENSE_KEY" },
  settings: [
    { key: "CHATBOX_LICENSE_KEY", title: "API key", type: "secure" },
    { key: "MESSAGES", title: "Chatbox AI", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const messages = JSON.parse(ctx.settings.get("MESSAGES") || "{}");
    const message = (key, status) => (messages[key] || key) + (status === undefined ? "" : ` (HTTP ${status})`);
    const key = ctx.settings.getSecret("CHATBOX_LICENSE_KEY");
    if (
      !key ||
      key.length > 4096 ||
      /\s/u.test(key) ||
      Array.from(key).some((character) => {
        const code = character.charCodeAt(0);
        return code < 32 || (code >= 127 && code <= 159);
      })
    ) {
      throw ctx.fail.authenticationExpired(message("Chatbox AI license key is invalid. Update it in Settings."));
    }
    const response = await ctx.http.get("https://api.chatboxai.app/api/license/detail/realtime", {
      headers: { "Cache-Control": "no-store" },
    });
    const record = (value) => (value && typeof value === "object" && !Array.isArray(value) ? value : undefined);
    const decode = (body) => {
      try {
        return record(JSON.parse(body));
      } catch (error) {
        void error;
        return undefined;
      }
    };
    if (response.status === 401) {
      throw ctx.fail.authenticationExpired(
        message("Chatbox AI license key is invalid. Update it in Settings.", response.status),
      );
    }
    if (response.status === 403) {
      throw ctx.fail.permissionDenied(message("Chatbox AI denied access. Check your license.", response.status));
    }
    if (response.status === 429) {
      const delay = Number(_nullishCoalesce(response.headers["retry-after"], () => 1));
      throw ctx.fail.rateLimited(message("Chatbox AI is rate limiting requests. Try again later.", response.status), {
        retryAfterSeconds: Number.isFinite(delay) && delay >= 0 ? Math.min(delay, 10) : 1,
      });
    }
    if (response.status >= 500) {
      throw ctx.fail.providerUnavailable(message("Chatbox AI request failed. Try refreshing later.", response.status));
    }
    if (response.status !== 200) {
      throw ctx.fail.apiFailure(message("Chatbox AI request failed. Try refreshing later.", response.status));
    }
    const fail = () => {
      throw ctx.fail.parseFailure(
        message("Chatbox AI returned an unrecognized response. Update CodexBar and try again."),
      );
    };
    const root = decode(response.bodyText);
    const data = record(_optionalChain([root, "optionalAccess", (_) => _.data]));
    if (!data || _optionalChain([root, "optionalAccess", (_2) => _2.error])) return fail();
    const now = ctx.date.now().getTime();
    const text = (value) =>
      typeof value === "string"
        ? Array.from(value, (character) => {
            const code = character.charCodeAt(0);
            return code < 32 || code === 127 ? " " : character;
          })
            .join("")
            .trim()
            .slice(0, 100) || undefined
        : undefined;
    const counter = (value) => {
      if (value === undefined || value === null) return undefined;
      return typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : fail();
    };
    const date = (value) => {
      if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T/.test(value)) return undefined;
      const parsed = new Date(value);
      return Number.isFinite(parsed.getTime()) && parsed.getUTCFullYear() >= 1970 ? parsed : undefined;
    };

    const pool = (object, usedKey, limitKey) => {
      const used = counter(object[usedKey]);
      const limit = counter(object[limitKey]);
      return used !== undefined && limit !== undefined ? { used, limit } : undefined;
    };
    const rows = [];
    const addPool = (label, value) => {
      if (!value || (value.used === 0 && value.limit === 0)) return;
      const remaining = Math.max(value.limit - value.used, 0);
      rows.push({
        label,
        value: `${ctx.format.number(remaining)} / ${ctx.format.number(value.limit)}`,
        usageValue: value.used,
      });
    };
    const details = data.unified_token_usage_details;
    let plan;
    let detailRewards;
    if (details !== undefined && details !== null) {
      if (!Array.isArray(details) || details.length > 100) return fail();
      for (const entry of details) {
        const item = record(entry);
        if (!item || typeof item.type !== "string") return fail();
        const value = pool(item, "token_usage", "token_limit");
        if (item.type === "plan") {
          if (plan) return fail();
          plan = value;
        } else if (value) {
          const expires = date(item.expires_at);
          if (expires && expires.getTime() <= now) continue;
          detailRewards = {
            used:
              _nullishCoalesce(_optionalChain([detailRewards, "optionalAccess", (_3) => _3.used]), () => 0) +
              value.used,
            limit:
              _nullishCoalesce(_optionalChain([detailRewards, "optionalAccess", (_4) => _4.limit]), () => 0) +
              value.limit,
          };
          if (!Number.isSafeInteger(detailRewards.used) || !Number.isSafeInteger(detailRewards.limit)) return fail();
        }
      }
    }
    const total = pool(data, "unified_token_usage", "unified_token_limit");
    const rewardRecord = record(data.aggregated_reward_details);
    if (data.aggregated_reward_details != null && !rewardRecord) return fail();
    const rewards = rewardRecord ? pool(rewardRecord, "token_usage", "token_limit") : detailRewards;
    const expansion = pool(data, "expansion_pack_usage", "expansion_pack_limit");
    const images = pool(data, "image_used_count", "image_total_quota");
    if (!plan && !total && !rewards && !expansion && !images) return fail();
    addPool("Plan", plan);
    if (!plan) addPool("Quota", total);
    addPool("Credits", rewards);
    addPool("Top-up credits", expansion);
    addPool("Image Generation", images);
    const name = text(data.name);
    const status = text(data.status);
    const expires = _nullishCoalesce(date(data.token_expire_time), () => date(data.expires_at));
    const next = date(data.token_next_refresh_time);
    const usablePlan = (status === undefined || status === "active") && (!expires || expires.getTime() > now);
    // Trial has no positive plan pool. Rewards and image totals do not share the plan's reset schedule.
    const reset =
      usablePlan &&
      plan &&
      plan.limit > 0 &&
      next &&
      next.getTime() > now &&
      (!expires || next.getTime() < expires.getTime())
        ? next
        : undefined;
    if (rows.length === 0) rows.push({ label: "Quota", value: "0 / 0", usageValue: 0 });
    return {
      primary:
        usablePlan && plan && plan.limit > 0
          ? {
              usedPercent: ctx.pct(plan.used, plan.limit),
              resetsAt: reset,
            }
          : undefined,
      secondary:
        expansion && expansion.limit > 0 ? { usedPercent: ctx.pct(expansion.used, expansion.limit) } : undefined,
      identity: name ? { loginMethod: name } : undefined,
      details: [{ title: "Remaining", rows }],
      subscriptionExpiresAt: expires,
      dataConfidence: "exact",
    };
  },
});
