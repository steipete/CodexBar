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
  id: "llmman",
  name: "llmman",
  endpoints: [{ setting: "LLMMAN_HOST", policy: "https-or-private-network-http" }],
  settings: [
    { key: "LLMMAN_API_KEY", title: "API key", type: "secure" },
    { key: "LLMMAN_HOST", title: "Base URL", type: "plain" },
  ],
  capabilities: ["http-status"],
  async fetchUsage(ctx) {
    // Accept the OpenAI-style base URL agents are given, too.
    const base = (ctx.settings.get("LLMMAN_HOST") || "").replace(/\/+$/u, "").replace(/\/v1$/u, "");
    // Optional: a daemon without LLMMAN_API_KEYS is open (and loopback-only).
    const key = ctx.settings.getSecret("LLMMAN_API_KEY");
    const headers = key ? { Authorization: `Bearer ${key}` } : {};
    const get = async (path) => {
      try {
        return await ctx.http.get(`${base}${path}`, { headers, timeoutSeconds: 5 });
      } catch (error) {
        if (error.transportClass === "cancelled") throw error;
        throw ctx.fail.networkFailure(`llmman is not reachable at ${base}. Start it with llmman serve.`);
      }
    };
    const response = await get("/llmman/node");
    if (response.status === 401 || response.status === 403) {
      if (!key) throw ctx.fail.missingCredential("llmman requires an API key. Set one in Settings or LLMMAN_API_KEY.");
      throw ctx.fail.authenticationExpired(`llmman rejected the API key (HTTP ${response.status}).`);
    }
    if (response.status === 429) throw ctx.fail.rateLimited("llmman is busy.");
    if (response.status >= 500) throw ctx.fail.providerUnavailable(`llmman error: HTTP ${response.status}`);
    if (response.status !== 200)
      throw ctx.fail.apiFailure(`${base} is not an llmman daemon (HTTP ${response.status}).`);

    const fail = () => {
      throw ctx.fail.parseFailure("llmman returned an unrecognized /llmman/node response.");
    };
    let node;
    try {
      node = JSON.parse(response.bodyText);
    } catch (error) {
      void error;
      return fail();
    }
    const bytes = (value) => (typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : fail());
    const models = (value) => {
      if (!value || typeof value !== "object" || Array.isArray(value)) return fail();
      return Object.entries(value)
        .map(([name, size]) => [name, bytes(size)])
        .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1));
    };
    if (!node || typeof node !== "object") return fail();
    const memory = bytes(node.memory);
    const loaded = models(node.loaded);
    const stored = models(node.stored);
    const total = (list) => list.reduce((sum, [, size]) => sum + size, 0);
    const inUse = total(loaded);

    // Decimal units, as llmman's own list/ps print them.
    const size = (value) => {
      if (value < 1e3) return `${value} B`;
      const [unit, scale] = value >= 1e9 ? ["GB", 1e9] : value >= 1e6 ? ["MB", 1e6] : ["kB", 1e3];
      return `${ctx.format.number(value / scale, { minimumFractionDigits: 1, maximumFractionDigits: 1 })} ${unit}`;
    };
    const count = (list) => `${list.length} · ${size(total(list))}`;

    // Best effort: the version is display-only, and older daemons may answer differently.
    let version;
    try {
      const reply = await get("/api/version");
      const value =
        reply.status === 200
          ? _optionalChain([
              JSON,
              "access",
              (_) => _.parse,
              "call",
              (_2) => _2(reply.bodyText),
              "optionalAccess",
              (_3) => _3.version,
            ])
          : undefined;
      if (typeof value === "string" && ctx.isDetailLabel(value)) version = value;
    } catch (error) {
      if (error.transportClass === "cancelled") throw error;
    }

    const summary = [
      { label: "Loaded", value: count(loaded) },
      { label: "Stored", value: count(stored) },
      ...(version ? [{ label: "Version", value: version }] : []),
    ];
    const rows = loaded
      .filter(([name]) => ctx.isDetailLabel(name))
      .slice(0, 24)
      .map(([name, weight]) => ({
        label: name,
        value: size(weight),
        ...(memory > 0 ? { progress: Math.min(1, weight / memory) } : {}),
      }));
    return {
      primary:
        memory > 0
          ? { usedPercent: ctx.pct(inUse, memory), resetDescription: `${size(inUse)} of ${size(memory)}` }
          : null,
      details: [{ title: "Daemon", rows: summary }, ...(rows.length ? [{ title: "Loaded models", rows }] : [])],
      identity: { loginMethod: key ? "API key" : "Local daemon" },
      dataConfidence: "exact",
    };
  },
});
