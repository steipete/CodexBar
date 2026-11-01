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

function aiandDecimal(raw) {
  const match = raw.trim().match(/^([+-]?)(\d+(?:\.\d*)?|\.\d+)(?:[eE]([+-]?\d+))?$/);
  if (!match) return;
  const mantissa = match[2].replace(/(\.\d*?)0+$/, "$1");
  const fraction = _nullishCoalesce(
    _optionalChain([
      mantissa,
      "access",
      (_) => _.split,
      "call",
      (_2) => _2("."),
      "access",
      (_3) => _3[1],
      "optionalAccess",
      (_4) => _4.length,
    ]),
    () => 0,
  );
  const exponent = Number(_nullishCoalesce(match[3], () => 0));
  const scale = fraction - exponent;
  // Bound exponent work before constructing powers, matching Decimal's exponent range.
  if (!Number.isInteger(scale) || exponent < -128 || exponent > 127 || scale > 128) return;
  return { coefficient: BigInt(`${match[1] === "-" ? "-" : ""}${mantissa.replace(".", "") || "0"}`), scale };
}

defineProvider({
  id: "aiand",
  name: "ai&",
  endpoints: ["https://api.aiand.com"],
  auth: { type: "bearer", secret: "AIAND_API_KEY" },
  capabilities: ["http-status"],
  settings: [{ key: "AIAND_API_KEY", title: "API key", type: "secure" }],
  async fetchUsage(ctx) {
    let after, afterID, currency;
    let balanceResponse = null;
    let total = { coefficient: 0n, scale: 0 },
      complete = false;
    const invalid = () => ctx.fail.parseFailure("Could not parse ai& usage: invalid logs payload.");
    const optionalString = (value) => {
      if (value == null) return;
      if (typeof value !== "string") throw invalid();
      return value;
    };
    for (let page = 0; page < 10; page++) {
      let url = "https://api.aiand.com/logs?range=30days&limit=100";
      if (after !== undefined && afterID !== undefined) {
        url += `&after=${encodeURIComponent(after)}&after_id=${encodeURIComponent(afterID)}`;
      }
      let response;
      if (page === 0) {
        const initial = await ctx.http.getWithOptional(url, "https://api.aiand.com/billing/balance", {
          timeoutSeconds: 15,
        });
        response = initial;
        balanceResponse = initial.optional;
      } else {
        response = await ctx.http.get(url, { timeoutSeconds: 15 });
      }
      if (response.status === 401)
        throw ctx.fail.authenticationExpired(
          "ai& rejected the API key. Create a new key at console.aiand.com and update Settings.",
        );
      if (response.status === 402)
        throw ctx.fail.apiFailure("ai& reports the organization is out of credits. Top up at console.aiand.com.");
      if (response.status === 429)
        throw ctx.fail.rateLimited("ai& rate limit exceeded. Usage will refresh on the next cycle.");
      if (response.status < 200 || response.status >= 300)
        throw ctx.fail.apiFailure(`ai& logs API returned HTTP ${response.status}.`);
      let data;
      try {
        data = JSON.parse(response.bodyText);
      } catch (error) {
        void error;
        throw invalid();
      }
      if (!data || !Array.isArray(data.data) || (data.has_more != null && typeof data.has_more !== "boolean"))
        throw invalid();
      after = optionalString(data.next_after);
      afterID = optionalString(data.next_after_id);
      for (const row of data.data) {
        if (!row || typeof row !== "object" || Array.isArray(row)) throw invalid();
        const rawCost = optionalString(row.cost),
          code = _optionalChain([
            optionalString,
            "call",
            (_5) => _5(row.currency),
            "optionalAccess",
            (_6) => _6.trim,
            "call",
            (_7) => _7(),
            "access",
            (_8) => _8.toUpperCase,
            "call",
            (_9) => _9(),
          ]);
        const cost = rawCost === undefined ? undefined : aiandDecimal(rawCost);
        if (!cost || !code) continue;
        currency ??= code;
        if (code !== currency) continue;
        const scale = Math.max(total.scale, cost.scale);
        total = {
          coefficient:
            total.coefficient * 10n ** BigInt(scale - total.scale) +
            cost.coefficient * 10n ** BigInt(scale - cost.scale),
          scale,
        };
      }
      if (!data.has_more) {
        complete = true;
        break;
      }
      // The API requires both cursors; never turn a truncated window into an exact total.
      if (after === undefined || afterID === undefined) break;
    }
    let details;
    if (_optionalChain([balanceResponse, "optionalAccess", (_10) => _10.status]) === 200) {
      try {
        const wallet = JSON.parse(balanceResponse.bodyText);
        if (wallet && typeof wallet === "object" && !Array.isArray(wallet)) {
          const { balance, currency: code } = wallet;
          if (
            typeof balance === "string" &&
            // Leave room for the currency code within the native detail value's 120-character limit.
            balance.trim().length + 4 <= 120 &&
            /^-?\d+(?:\.\d+)?$/.test(balance.trim()) &&
            aiandDecimal(balance) &&
            typeof code === "string" &&
            /^(usd|jpy)$/i.test(code)
          ) {
            // Preserve the ledger's decimal precision, including fractional JPY and negative balances.
            // This is settled org credit; pending requests/reservations can reduce spendable funds.
            details = [
              {
                title: "Organization wallet",
                rows: [{ label: "Settled wallet balance", value: `${balance.trim()} ${code.toUpperCase()}` }],
              },
            ];
          }
        }
      } catch (error) {
        // Optional reporting must never erase valid log-derived spend.
        void error;
      }
    }
    return {
      empty: true,
      details,
      cost: currency
        ? {
            used: Number(`${total.coefficient}e${-total.scale}`),
            limit: 0,
            currency,
            period: complete ? "Last 30 days" : "Last 30 days (partial)",
          }
        : undefined,
      dataConfidence: complete ? "exact" : "estimated",
    };
  },
});
