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
  id: "qwencloud",
  name: "Qwen Cloud",
  endpoints: ["https://home.qwencloud.com"],
  settings: [],
  capabilities: ["browser-cookies", "http-status"],
  cookieDomains: ["home.qwencloud.com"],
  cookiePolicy: { selection: "request-url", cache: "nonpersistent" },
  async fetchUsage(ctx) {
    const base = "https://home.qwencloud.com";
    const fail = (field) => {
      throw ctx.fail.parseFailure(`Unsupported Qwen Cloud Team ${field}. Check Usage Dashboard.`);
    };
    const record = (value) =>
      value !== null && typeof value === "object" && !Array.isArray(value) ? value : undefined;
    const number = (value) => {
      if (typeof value !== "number" && (typeof value !== "string" || !/^\d+(?:\.\d+)?$/.test(value)))
        return fail("credit count");
      const parsed = Number(value);
      return Number.isFinite(parsed) && parsed >= 0 && parsed <= Number.MAX_SAFE_INTEGER
        ? parsed
        : fail("credit count");
    };
    const json = (response) => {
      if (response.status === 401 || response.status === 403)
        throw ctx.fail.authenticationExpired("Qwen Cloud Team session expired. Sign in again.");
      if (response.status === 429) throw ctx.fail.rateLimited("Qwen Cloud Team rate limit reached.");
      if (response.status !== 200) throw ctx.fail.apiFailure(`Qwen Cloud Team returned HTTP ${response.status}.`);
      let payload;
      try {
        payload = JSON.parse(response.bodyText);
      } catch (error) {
        void error;
        return fail("response");
      }
      const root = _nullishCoalesce(record(payload), () => fail("response"));
      if (
        typeof root.code === "string" &&
        ["ConsoleNeedLogin", "BailianGateway.Login.NotLogined", "NO_LOGIN"].includes(root.code)
      )
        throw ctx.fail.authenticationExpired("Qwen Cloud Team login required.");
      return root;
    };
    for await (const session of ctx.browser.sessions("home.qwencloud.com")) {
      const options = {
        cookieSession: session.id,
        timeoutSeconds: 8,
        headers: { Accept: "application/json", Referer: `${base}/analytics/token-plan/team` },
      };
      const info = json(await ctx.http.get(`${base}/tool/user/info.json`, options));
      const token = _optionalChain([record, "call", (_) => _(info.data), "optionalAccess", (_2) => _2.secToken]);
      if (typeof token !== "string" || !token.trim())
        throw ctx.fail.authenticationExpired("Qwen Cloud Team login required.");
      const rpc = async (product, action, params, region) => {
        const form = {
          product,
          action,
          sec_token: token,
          region,
          params: JSON.stringify(params),
        };
        if (action === "GetSeatSubscriptionSummary") form.language = "zh-CN";
        const root = json(
          await ctx.http.post(`${base}/data/api.json?product=${product}&action=${action}`, {
            ...options,
            headers: { ...options.headers, Origin: base },
            form,
          }),
        );
        const result = record(root.data);
        if (root.successResponse === false || _optionalChain([result, "optionalAccess", (_3) => _3.Success]) === false)
          throw ctx.fail.apiFailure(`Qwen Cloud Team ${action} failed.`);
        if ((root.successResponse !== true && root.code !== "200") || !result) return fail("gateway envelope");
        return result;
      };
      // The console discovers this billing selector; it is not the login UID or a saved workspace ID.
      const human = await rpc("ea-service", "LoadHumanInfo", {}, "ap-southeast-1");
      const nbid = _optionalChain([
        record,
        "call",
        (_4) =>
          _4(_optionalChain([record, "call", (_5) => _5(human.Data), "optionalAccess", (_6) => _6.SellerInfoDto])),
        "optionalAccess",
        (_7) => _7.Nbid,
      ]);
      const params = { productCode: "sfm_tokenplanteams_dp_intl" };
      if (nbid !== undefined && nbid !== null && nbid !== "") {
        if (typeof nbid !== "string" || !nbid.trim()) return fail("billing selector");
        params.Nbid = nbid;
      }
      const summary = await rpc("BssOpenAPI-V3", "GetSeatSubscriptionSummary", params, "cn-hangzhou");
      const data = _nullishCoalesce(record(summary.Data === null ? {} : summary.Data), () => fail("subscription"));
      if (Object.keys(data).length === 0) return { empty: true };
      const groups = data.SubscriptionGroupList;
      if (!Array.isArray(groups)) return fail("subscription groups");
      if (!groups.length) return { empty: true };
      const start = number(data.StartTime);
      const end = number(data.EndTime);
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start <= 0 || end <= start)
        return fail("subscription period");
      const now = ctx.date.now().getTime();
      if (now < start || now >= end) return { empty: true };
      if (data.ProductCode !== "sfm_tokenplanteams_dp_intl") return fail("subscription product");
      if (groups.length !== 1) return fail("multiple credit pools");
      const group = _nullishCoalesce(record(groups[0]), () => fail("subscription group"));
      if (!Array.isArray(group.EquityList)) return fail("credit equity");
      const equities = group.EquityList.map(record).filter(
        (equity) => _optionalChain([equity, "optionalAccess", (_8) => _8.EquityCode]) === "credit_value",
      );
      if (equities.length !== 1) return fail("credit equity");
      const total = number(
        _optionalChain([equities, "access", (_9) => _9[0], "optionalAccess", (_10) => _10.TotalValue]),
      );
      const remaining = number(
        _optionalChain([equities, "access", (_11) => _11[0], "optionalAccess", (_12) => _12.SurplusValue]),
      );
      if (total <= 0 || remaining > total) return fail("credit count");
      const used = total - remaining;
      const format = (value) => ctx.format.number(value, { maximumFractionDigits: 2 });
      const rows = [
        { label: "Credits", value: `${format(used)} / ${format(total)} credits used` },
        { label: "Remaining", value: `${format(remaining)} credits` },
      ];
      const assigned = group.SubscriptionAssignedNumber;
      const seats = group.SubscriptionTotalNumber;
      if (
        typeof assigned === "number" &&
        typeof seats === "number" &&
        Number.isSafeInteger(assigned) &&
        Number.isSafeInteger(seats) &&
        assigned >= 0 &&
        seats >= assigned
      )
        rows.push({ label: "Seats", value: `${assigned} / ${seats}` });
      let reset;
      if (group.NextCycleFlushTime !== undefined && group.NextCycleFlushTime !== null) {
        const millis = number(group.NextCycleFlushTime);
        if (!Number.isSafeInteger(millis) || millis <= 0) return fail("cycle reset");
        reset = ctx.date.unixMillis(millis);
      }
      const spec =
        typeof group.SpecType === "string" && /^[a-z][a-z0-9_-]{0,39}$/.test(group.SpecType)
          ? `${group.SpecType[0].toUpperCase()}${group.SpecType.slice(1)} Team`
          : "Team Token Plan";
      return {
        primary: { usedPercent: ctx.pct(used, total), resetsAt: reset, resetDescription: "Team" },
        identity: { loginMethod: spec },
        details: [{ title: "Team Token Plan", rows }],
      };
    }
    throw ctx.fail.missingCredential("No Qwen Cloud Team session cookies available.");
  },
});
