// Pure model shared by the QML frontend and offline Node tests.
function remaining(window) {
    if (!window || typeof window.usedPercent !== "number" || !isFinite(window.usedPercent)) return null;
    return Math.round(Math.max(0, Math.min(100, 100 - window.usedPercent)));
}

function rows(text) {
    var decoded = JSON.parse(text);
    var entries = Array.isArray(decoded) ? decoded : [decoded];
    if (!entries.length || entries.some(function(e) { return !e || typeof e.provider !== "string"; }))
        throw new Error("Invalid usage response");
    return entries.map(function(entry) {
        var usage = entry.usage || {};
        var windows = [];
        ["primary", "secondary", "tertiary"].forEach(function(key, index) {
            var window = usage[key];
            var left = remaining(window);
            if (left === null) return;
            var minutes = window.windowMinutes;
            var label = minutes >= 1440 ? (minutes / 1440) + " day" :
                minutes > 0 ? (minutes / 60) + " hour" : ["Session", "Weekly", "Additional"][index];
            windows.push({label: label, remaining: left, resetsAt: window.resetsAt || ""});
        });
        return {
            provider: entry.provider,
            source: entry.source || "",
            windows: windows,
            updatedAt: usage.updatedAt || "",
            credits: entry.credits && typeof entry.credits.remaining === "number" ? entry.credits.remaining : null,
            error: entry.error ? "Usage unavailable. Check this provider’s CodexBar login/configuration." :
                windows.length ? "" : "No quota windows reported."
        };
    });
}

function summary(entries) {
    return entries.map(function(entry) {
        var label = entry.provider === "codex" ? "CX" : entry.provider === "claude" ? "CL" : entry.provider;
        return label + " " + (entry.windows.length ? entry.windows[0].remaining + "%" : "—");
    }).join("  ·  ");
}

function resetLabel(value, now) {
    var timestamp = Date.parse(value);
    if (!isFinite(timestamp)) return "Reset time unavailable";
    var minutes = Math.ceil((timestamp - now) / 60000);
    if (minutes <= 0) return "Reset due · refresh to update";
    if (minutes < 60) return "Resets in " + minutes + "m";
    if (minutes < 1440) return "Resets in " + Math.floor(minutes / 60) + "h " + minutes % 60 + "m";
    return "Resets in " + Math.floor(minutes / 1440) + "d " + Math.floor(minutes % 1440 / 60) + "h";
}
