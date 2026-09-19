function _nullishCoalesce(lhs, rhsFn) {
  if (lhs != null) {
    return lhs;
  } else {
    return rhsFn();
  }
}

defineProvider({
  id: "huggingface",
  name: "Hugging Face",
  endpoints: ["https://huggingface.co"],
  auth: { type: "bearer", secret: "HF_TOKEN" },
  settings: [{ key: "HF_TOKEN", title: "Access token", type: "secure" }],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    const fail = (field) => {
      throw ctx.fail.parseFailure(`Hugging Face billing response format changed: ${field}`);
    };
    const object = (value, field) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail(field);
      return value;
    };
    const number = (value, field) => {
      if (typeof value !== "number" || !Number.isFinite(value) || value < 0) return fail(field);
      return value;
    };
    const optionalNumber = (value, field) => (value === undefined || value === null ? undefined : number(value, field));
    const parse = (body) => {
      let value;
      try {
        value = JSON.parse(body);
      } catch (error) {
        void error;
        return fail("invalid JSON");
      }
      return object(value, "expected an object");
    };
    const date = (value) => {
      if (value === undefined || value === null) return undefined;
      if (typeof value === "number") {
        if (!Number.isFinite(value) || value <= 0 || value > 64092211200) return undefined;
        return ctx.date.unixSeconds(value);
      }
      if (typeof value === "string") {
        try {
          return ctx.date.iso(value);
        } catch (error) {
          void error;
        }
      }
      return undefined;
    };
    const text = (value) => (typeof value === "string" ? value.trim() || undefined : undefined);
    const now = ctx.date.now();
    const start = Math.floor(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1) / 1000);
    const end = Math.floor(now.getTime() / 1000);
    const response = await ctx.http.get(
      `https://huggingface.co/api/settings/billing/usage-v2?startDate=${start}&endDate=${end}`,
      { timeoutSeconds: 15, headers: { "User-Agent": "CodexBar" } },
    );
    if (response.status === 401) {
      throw ctx.fail.authenticationExpired("Hugging Face rejected the token. Check that it is valid and not expired.");
    }
    if (response.status === 403) {
      throw ctx.fail.permissionDenied(
        "The Hugging Face token lacks billing access. Use a classic read token or enable Billing read on a fine-grained token.",
      );
    }
    if (response.status === 429) throw ctx.fail.rateLimited("Hugging Face rate limit reached. Retry later.");
    if (response.status >= 500)
      throw ctx.fail.providerUnavailable(`Hugging Face API returned HTTP ${response.status}.`);
    if (response.status < 200 || response.status >= 300) {
      throw ctx.fail.apiFailure(`Hugging Face API returned HTTP ${response.status}.`);
    }
    const usage = object(parse(response.bodyText).usage, "missing usage");
    const inference = object(usage.inferenceProviders, "missing inferenceProviders usage");
    const gross = number(inference.usedNanoUsd, "usedNanoUsd") / 1e9;
    const included = number(inference.includedNanoUsd, "includedNanoUsd") / 1e9;
    const billable = Math.max(0, gross - included);
    const limit = _nullishCoalesce(optionalNumber(inference.limitNanoUsd, "limitNanoUsd"), () => 0) / 1e9;
    const requests = optionalNumber(inference.numRequests, "numRequests");
    if (requests !== undefined && !Number.isSafeInteger(requests)) return fail("numRequests");
    let secondary;
    let gpuRows = [];
    try {
      const gpuResponse = await ctx.http.get("https://huggingface.co/api/spaces/zero-gpu/quota", { timeoutSeconds: 2 });
      if (gpuResponse.status >= 200 && gpuResponse.status < 300) {
        const gpu = parse(gpuResponse.bodyText);
        const total = number(gpu.base, "ZeroGPU base");
        const remaining = number(gpu.current, "ZeroGPU current");
        if (total > 0) {
          const consumed = Math.max(0, total - remaining);
          secondary = {
            usedPercent: ctx.pct(consumed, total),
            resetsAt: date(gpu.resetsAt),
            resetDescription: "ZeroGPU quota",
          };
          const minutes = (seconds) =>
            `${ctx.format.number(seconds / 60, {
              minimumFractionDigits: seconds >= 600 ? 0 : 1,
              maximumFractionDigits: seconds >= 600 ? 0 : 1,
            })} min`;
          gpuRows = [
            { label: "GPU time used", value: minutes(consumed) },
            { label: "GPU time remaining", value: minutes(remaining) },
          ];
        }
      }
    } catch (error) {
      void error;
    }
    const cacheKey = "whoami-v2:" + ctx.settings.getSecret("HF_TOKEN");
    let identity = ctx.cache.get(cacheKey);
    if (!identity || now.getTime() - identity.fetchedAt < 0 || now.getTime() - identity.fetchedAt >= 43200000) {
      identity = undefined;
      try {
        const whoami = await ctx.http.get("https://huggingface.co/api/whoami-v2", { timeoutSeconds: 2 });
        if (whoami.status >= 200 && whoami.status < 300) {
          const profile = parse(whoami.bodyText);
          const username = text(profile.name);
          const email = text(profile.email);
          if (username || email) {
            identity = {
              fetchedAt: now.getTime(),
              username,
              email,
              plan: typeof profile.isPro === "boolean" ? (profile.isPro ? "PRO" : "Free") : undefined,
            };
            ctx.cache.set(cacheKey, identity, 43200);
          }
        }
      } catch (error) {
        void error;
      }
    }
    // usage-v2 reports a query interval; its cutoff is not a quota reset.
    // HF's billing UI deducts includedNanoUsd from usedNanoUsd to calculate the charge.
    const rows = [{ label: "Billable usage", value: ctx.format.usd(billable) }];
    if (included > 0) {
      rows.push({ label: "Gross inference usage", value: ctx.format.usd(gross) });
      rows.push({ label: "Included inference amount", value: ctx.format.usd(included) });
    }
    if (limit > 0) rows.push({ label: "Spending limit", value: ctx.format.usd(limit) });
    if (requests !== undefined) rows.push({ label: "Requests", value: String(requests) });
    const details = [{ title: "Inference Providers", rows }];
    if (gpuRows.length) details.push({ title: "ZeroGPU", rows: gpuRows });
    return {
      secondary,
      cost: { used: billable, limit: limit > 0 ? limit : undefined, currency: "USD", period: "This month" },
      details,
      identity: identity
        ? { email: identity.email, accountID: identity.username, loginMethod: identity.plan }
        : undefined,
      dataConfidence: "exact",
    };
  },
});
