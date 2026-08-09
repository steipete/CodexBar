defineProvider({
  id: "venice",
  name: "Venice",
  endpoints: ["https://api.venice.ai"],
  auth: { type: "bearer", secret: "VENICE_API_KEY" },
  settings: [
    {
      key: "VENICE_API_KEY",
      title: "API key",
      subtitle: "Venice API key used for the billing balance endpoint.",
      type: "secure",
    },
  ],

  async fetchUsage(ctx) {
    const response = await ctx.http.getJSON("https://api.venice.ai/api/v1/billing/balance");
    if (response.status !== 200) throw new Error(`Venice API error: HTTP ${response.status}`);

    const payload = response.json;
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      throw new Error("Failed to parse Venice response: expected an object");
    }
    if (typeof payload.canConsume !== "boolean") {
      throw new Error("Failed to parse Venice response: canConsume must be a boolean");
    }
    if (!payload.balances || typeof payload.balances !== "object" || Array.isArray(payload.balances)) {
      throw new Error("Failed to parse Venice response: balances must be an object");
    }

    function optionalNumber(value, field) {
      if (value === null || value === undefined || value === "") return null;
      const number = typeof value === "number" ? value : typeof value === "string" ? Number(value.trim()) : Number.NaN;
      if (!Number.isFinite(number)) throw new Error(`Failed to parse Venice response: ${field} must be numeric`);
      return number;
    }

    if (
      payload.consumptionCurrency !== null &&
      payload.consumptionCurrency !== undefined &&
      typeof payload.consumptionCurrency !== "string"
    ) {
      throw new Error("Failed to parse Venice response: consumptionCurrency must be a string");
    }
    const currency = payload.consumptionCurrency ? payload.consumptionCurrency.toUpperCase() : null;
    const diem = optionalNumber(payload.balances.diem, "balances.diem");
    const usd = optionalNumber(payload.balances.usd, "balances.usd");
    const allocation = optionalNumber(payload.diemEpochAllocation, "diemEpochAllocation");

    let usedPercent;
    let resetDescription;
    if (!payload.canConsume) {
      usedPercent = 100;
      resetDescription = "Balance unavailable for API calls";
    } else if (currency === "USD" && usd !== null && usd > 0) {
      usedPercent = 0;
      resetDescription = `$${usd.toFixed(2)} USD remaining`;
    } else if (currency !== "USD" && diem !== null && allocation !== null && allocation > 0) {
      usedPercent = ctx.pct(allocation - diem, allocation);
      resetDescription = `DIEM ${diem.toFixed(2)} / ${allocation.toFixed(2)} epoch allocation`;
    } else if (currency === "DIEM" && diem !== null && diem > 0) {
      usedPercent = 0;
      resetDescription = `DIEM ${diem.toFixed(2)} remaining`;
    } else if (diem !== null && diem > 0) {
      usedPercent = 0;
      resetDescription = `DIEM ${diem.toFixed(2)} remaining`;
    } else if (usd !== null && usd > 0) {
      usedPercent = 0;
      resetDescription = `$${usd.toFixed(2)} USD remaining`;
    } else {
      usedPercent = 100;
      resetDescription = "No Venice API balance available";
    }

    return {
      primary: { usedPercent, resetDescription },
      identity: {},
    };
  },
});
