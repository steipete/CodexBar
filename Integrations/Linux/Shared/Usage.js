// Pure model shared by the QML frontend and offline Node tests.
function remaining(window) {
    if (!window || typeof window.usedPercent !== "number" || !isFinite(window.usedPercent)) return null;
    // A provider can describe a window it cannot measure: Claude emits a synthetic placeholder
    // when its web API reports no session. Core drops those rather than reading them as quota.
    if (window.isSyntheticPlaceholder === true) return null;
    return Math.round(Math.max(0, Math.min(100, 100 - window.usedPercent)));
}

// Zed reports an overdue invoice and Antigravity a reset-only pool, both carrying a full
// usedPercent with usageKnown false. They are context, not quota.
function measured(entry) {
    return !!entry && typeof entry.id === "string" && entry.id.trim() !== "" &&
        entry.usageKnown !== false && remaining(entry.window) !== null;
}

// Duration name for a reported cadence; empty when the provider omits window metadata.
function cadenceLabel(minutes) {
    if (minutes >= 1440) return (minutes / 1440) + " day";
    return minutes > 0 ? (minutes / 60) + " hour" : "";
}

function rows(text, showIdentity) {
    var decoded = JSON.parse(text);
    var entries = Array.isArray(decoded) ? decoded : [decoded];
    if (!entries.length || entries.some(function(e) { return !e || typeof e.provider !== "string"; }))
        throw new Error("Invalid usage response");
    return entries.map(function(entry, entryIndex) {
        var usage = entry.usage || {};
        var identity = usage.identity || {};
        var windows = [];
        var extras = (Array.isArray(usage.extraRateWindows) ? usage.extraRateWindows : []).filter(measured);
        // Antigravity lists every pool as a quota-summary extra and copies one per model family
        // into its positional windows. Show each representative in its positional slot under
        // the family's title and drop its extra copy: the tray and summary read the leading
        // windows, and the extra limit below must not hide a representative. The row keeps the
        // pool's own key, so its alert history follows it when another pool becomes binding.
        // Families are matched as Core selects them, because two families can report equal values.
        var families = {primary: /gemini/i, secondary: /claude|gpt/i};
        var represented = [];
        ["primary", "secondary", "tertiary"].forEach(function(key, index) {
            var window = usage[key];
            var left = remaining(window);
            if (left === null) return;
            var copy = entry.provider === "antigravity" && families[key] ? extras.filter(function(extra) {
                return extra.id.indexOf("antigravity-quota-summary-") === 0 &&
                    represented.indexOf(extra) === -1 && families[key].test(String(extra.title || "")) &&
                    extra.window.usedPercent === window.usedPercent &&
                    extra.window.windowMinutes === window.windowMinutes && extra.window.resetsAt === window.resetsAt;
            }).sort(function(a, b) {
                // Core breaks equal usage ties by the case-insensitive title.
                return String(a.title || "").toLowerCase().localeCompare(String(b.title || "").toLowerCase());
            })[0] : null;
            if (copy) represented.push(copy);
            var suppliedLabel = entry.rateWindowLabels && entry.rateWindowLabels[key];
            var safeLabel = typeof suppliedLabel === "string" ? displayText(suppliedLabel, false).trim() : "";
            var label = (copy && displayText(copy.title, false).trim()) ||
                cadenceLabel(window.windowMinutes) || safeLabel || ["Session", "Weekly", "Additional"][index];
            var pace = entry.pace && entry.pace[key] ? entry.pace[key] : null;
            windows.push({key: copy ? "extra:" + copy.id : key, label: label, minutes: number(window.windowMinutes),
                remaining: left, resetsAt: window.resetsAt || "", pace: pace ? String(pace.summary || "") : "",
                paceDelta: pace ? number(pace.deltaPercent) : null});
        });
        // Extras come last: a consumer resolving a cadence by first match must still find the
        // provider's general window rather than a lane scoped to one model.
        extras.filter(function(extra) { return represented.indexOf(extra) === -1; })
            .slice(0, 8).forEach(function(extra) {
            var scopedWindow = extra.window;
            // These labels are exported over IPC, whose contract excludes account identity,
            // so a provider-supplied title is redacted whatever the display preference says.
            var label = displayText(extra.title, false).trim() ||
                cadenceLabel(scopedWindow.windowMinutes) || "Additional";
            windows.push({key: "extra:" + extra.id, label: label, minutes: number(scopedWindow.windowMinutes),
                remaining: remaining(scopedWindow), resetsAt: scopedWindow.resetsAt || "", pace: "",
                paceDelta: null, scoped: true});
        });
        return {
            provider: entry.provider,
            failed: !!entry.error,
            accountLabel: showIdentity ? String(identity.accountEmail || usage.accountEmail || "") : "",
            accountNumber: entryIndex + 1,
            plan: String(identity.loginMethod || usage.loginMethod || ""),
            status: entry.status ? String(entry.status.description || entry.status.indicator || "Unknown") : "",
            statusLevel: entry.status ? String(entry.status.indicator || "unknown") : "unknown",
            details: Array.isArray(usage.details) ? usage.details.slice(0, 8).map(function(section) {
                return {title: String(section.title || ""), rows: (section.rows || []).slice(0, 24).map(function(row) {
                    return {label: String(row.label || ""), value: displayText(row.value, showIdentity),
                        secondaryValue: displayText(row.secondaryValue, showIdentity)};
                }), chart: chart(section.chart)};
            }) : [],
            source: entry.source || "",
            windows: windows,
            updatedAt: usage.updatedAt || "",
            credits: entry.credits && typeof entry.credits.remaining === "number" ? entry.credits.remaining : null,
            error: entry.error ? "Usage unavailable. Check this provider’s CodexBar login/configuration." :
                windows.length ? "" : "No quota windows reported."
        };
    });
}

function command(settings) {
    var provider = String(settings.provider || "codex");
    var args = ["timeout", "--kill-after=5", "60", String(settings.executable || "codexbar"),
        "usage", "--format", "json", "--json-only"];
    if (provider !== "enabled") args.push("--provider", provider);
    var source = String(settings.source || "auto");
    if (source !== "auto") args.push("--source", source);
    if (settings.showStatus !== false) args.push("--status");
    if (["enabled", "all", "both"].indexOf(provider) === -1) {
        if (settings.allAccounts === true) args.push("--all-accounts");
        else if (Number.isInteger(Number(settings.accountIndex)) && Number(settings.accountIndex) > 0)
            args.push("--account-index", String(settings.accountIndex));
    }
    return args;
}

function displayText(value, showIdentity) {
    var text = String(value || "").slice(0, 500);
    return showIdentity ? text : text.replace(/[^\s@]+@[^\s@]+/g, "[hidden email]");
}

function chart(value) {
    if (!value || !Array.isArray(value.points)) return null;
    var points = value.points.slice(0, 120).filter(function(point) {
        return point && typeof point.value === "number" && isFinite(point.value);
    }).map(function(point) { return {label: String(point.label || ""), value: point.value}; });
    return {title: String(value.title || ""), unit: String(value.unit || ""),
        kind: value.kind === "line" ? "line" : "bars", points: points};
}

function number(value) { return typeof value === "number" && isFinite(value) ? value : null; }

function money(value) { return number(value) === null ? "Unavailable" : "$" + value.toFixed(2); }

function count(value) {
    return number(value) === null ? "—" : Math.round(value).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function provenance(value) {
    return {listPriceEstimate: "List-price estimate", actual: "Reported cost", unknown: "Cost source unavailable"}[value] || value;
}

function costs(text, today) {
    if (!today) {
        var now = new Date();
        today = now.getFullYear() + "-" + String(now.getMonth() + 1).padStart(2, "0") + "-" + String(now.getDate()).padStart(2, "0");
    }
    var decoded = JSON.parse(text);
    if (!Array.isArray(decoded) || decoded.some(function(row) { return !row || typeof row.provider !== "string"; }))
        throw new Error("Invalid cost response");
    return decoded.map(function(row) {
        var totals = row.totals || {};
        var daily = Array.isArray(row.daily) ? row.daily.slice(-30) : [];
        var todayRow = daily.find(function(day) { return day.date === today; });
        return {provider: row.provider, today: todayRow ? number(todayRow.totalCost) :
                row.historyCoverageIsEstablished === true && !row.error ? 0 : null, month: number(row.last30DaysCostUSD),
            tokens: number(row.last30DaysTokens), input: number(totals.inputTokens), output: number(totals.outputTokens),
            cached: number(totals.cacheReadTokens), provenance: String(row.provenance || "unknown"),
            coverage: row.historyCoverageIsEstablished === true ? "Local history" : "History may be incomplete",
            error: row.error ? "Local cost history unavailable" : "",
            chart: chart({title: "Recorded daily cost · USD", unit: "USD", kind: "bars",
                points: daily.map(function(day) { return {label: day.date, value: day.totalCost}; })})};
    });
}

// Lane detection mirrors Core's ProviderUsagePresentation.standardSemanticWindows, so the bar
// follows the cadence a provider reports rather than a provider name or a slot position.
function tightest(windows) {
    return windows.slice().sort(function(a, b) { return a.remaining - b.remaining; })[0] || null;
}

function laneOfCadence(windows, matches) {
    // A provider can mark a set of extras as the summary of a cadence rather than caps beneath it:
    // Antigravity emits one per model family, ids carrying a quota-summary segment, and rows()
    // files the copied family under the pool's own key. Resolve across that whole set, or a
    // tighter family hides behind the one the provider copied. Percentages cannot stand in for
    // the marker: Claude's general weekly can coincide with one of its per-model caps.
    var summarised = windows.filter(function(item) {
        return matches(item) && item.key.indexOf("quota-summary") !== -1;
    });
    if (summarised.length) return tightest(summarised);
    var general = windows.filter(function(item) { return !item.scoped && matches(item); });
    if (general.length) return tightest(general);
    // A provider can publish only per-model lanes of a cadence and no general window; Antigravity
    // reports no general weekly at all. Core derives the lane as the most constrained of those.
    return tightest(windows.filter(function(item) { return item.scoped && matches(item); }));
}

function sessionWindow(windows) {
    return laneOfCadence(windows, function(item) { return item.minutes >= 60 && item.minutes <= 720; });
}

function weeklyWindow(windows) {
    return laneOfCadence(windows, function(item) { return item.minutes === 10080; });
}

// Compact cadence label: 10080 -> "7D", 300 -> "5H". A billing cycle is a real cadence and rarely
// a whole number of days, so name it in days rather than reporting 684H.
function laneLabel(minutes) {
    if (!minutes || minutes <= 0) return "";
    if (minutes >= 1440) return Math.round(minutes / 1440) + "D";
    if (minutes % 60 === 0) return (minutes / 60) + "H";
    return minutes + "M";
}

// Mirrors MenuBarDisplayText.paceText: positive is a deficit, negative a reserve. An unavailable
// pace stays unavailable; it is never reported as being on pace.
function paceDeltaText(delta) {
    if (number(delta) === null) return "";
    var value = Math.round(Math.abs(delta));
    return value === 0 ? "0%" : (delta >= 0 ? "+" : "-") + value + "%";
}

// The tightest general window of each cadence the caller has not already represented, shortest
// cadence first so the bar reads from most to least immediate.
function otherCadences(windows, shown) {
    var covered = shown.filter(Boolean);
    var best = {}, order = [], claimed = {};
    windows.forEach(function(item) { if (!item.scoped && item.minutes) claimed[item.minutes] = true; });
    var fallback = promotedFallback(windows);
    windows.forEach(function(item) {
        // An extra window is not always a sub-cap. Kimi delivers a subscription-only account's
        // whole quota this way, so let one stand in for a cadence no positional window claims.
        if (item.scoped && item !== fallback && (!item.minutes || claimed[item.minutes])) return;
        var key = item.minutes ? String(item.minutes) : "named:" + item.label;
        if (covered.some(function(seen) { return seen === item || (item.minutes && seen.minutes === item.minutes); })) return;
        // Same duration does not make two windows the same quota: Cursor bills its total, its
        // Auto/Composer usage and its API usage over one cycle, and lists its own quota first.
        if (best[key]) return;
        order.push(key);
        best[key] = item;
    });
    return order.sort(function(a, b) {
        var left = parseInt(a, 10), right = parseInt(b, 10);
        if (isNaN(left) && isNaN(right)) return order.indexOf(a) - order.indexOf(b);
        if (isNaN(left)) return 1;
        if (isNaN(right)) return -1;
        return left - right;
    }).map(function(key) { return best[key]; });
}

// Antigravity marks a compact fallback extra as its quota when neither model family has a pool
// to copy. Only that marked window stands in for the provider, so an image model at 1% cannot
// displace the text model, and once promoted it counts as the provider's own quota.
function promotedFallback(windows) {
    if (windows.some(function(item) { return !item.scoped; })) return null;
    return tightest(windows.filter(function(item) {
        return item.scoped && !item.minutes && item.key.indexOf("compact-fallback") !== -1;
    }));
}

function tightestGeneral(windows) {
    var fallback = promotedFallback(windows);
    return tightest(windows.filter(function(item) { return !item.scoped || item === fallback; }));
}

// Providers whose API labels a limit as one model's own budget. Such a cap shows even when it
// matches a lane; other extras, such as Antigravity's family pools, often repeat one.
var modelCaps = {claude: "extra:claude-weekly-scoped-", codex: "extra:codex-"};

// A cap scoped to one model earns bar space only while it binds harder than the general lane of
// its own cadence; Antigravity's per-model lanes report no cadence at all, so they are held to
// the provider's tightest general lane instead.
function bindingScope(item, session, weekly, windows) {
    var general = item.minutes === 10080 ? weekly
        : item.minutes >= 60 && item.minutes <= 720 ? session
        : null;
    // A cadence the bar derived from this very cap cannot be the lane it has to out-bind; hold it
    // to the provider's own quota instead, which includes a promoted compact fallback.
    if (!general || general === item) general = tightestGeneral(windows);
    return !general || item.remaining < general.remaining;
}

// One provider's bar text. Without `detail` this is the single leading percentage the adapter has
// always drawn, so an upgrade changes nothing until the preference is switched on.
function laneSegments(entry, mode, options) {
    var settings = options || {};
    var windows = entry.windows || [];
    var session = sessionWindow(windows);
    var weekly = weeklyWindow(windows);
    var segments = [], rendered = [];
    if (!settings.detail) {
        if (windows.length) {
            segments.push(quotaValue(windows[0].remaining, mode) + "%");
            rendered = [windows[0]];
        }
    } else {
        if (session) segments.push(laneLabel(session.minutes) + " " + quotaValue(session.remaining, mode) + "%");
        if (weekly) segments.push(laneLabel(weekly.minutes) + " " + quotaValue(weekly.remaining, mode) + "%");
        // A provider's own quota can use neither cadence: Cursor bills on a monthly cycle beside a
        // weekly allowance, so every cadence it reports itself gets a lane.
        var extra = otherCadences(windows, [session, weekly]);
        extra.forEach(function(item) {
            segments.push((laneLabel(item.minutes) || item.label) + " " + quotaValue(item.remaining, mode) + "%");
        });
        rendered = [session, weekly].concat(extra);
    }
    // A scoped cap is named by the provider, not by its cadence, because it usually shares one
    // with the general lane beside it. The bar drops the qualifier the provider appends.
    windows.forEach(function(item) {
        if (!settings.scopedCaps || !item.scoped || rendered.indexOf(item) !== -1) return;
        var prefix = modelCaps[entry.provider];
        if (!(prefix && item.key.indexOf(prefix) === 0) && !bindingScope(item, session, weekly, windows)) return;
        segments.push(item.label.replace(/\s+only$/i, "") + " " + quotaValue(item.remaining, mode) + "%");
    });
    // Pace belongs to the weekly window, not to whichever lane is most constrained, and it stays
    // last so the quota lanes read together. An unavailable pace gets no segment at all.
    if (settings.detail && settings.pace !== false && weekly && paceDeltaText(weekly.paceDelta))
        segments.push(paceDeltaText(weekly.paceDelta));
    return segments;
}

// Share the same labels and display limit between text and logo adapters. `maxProviders` is
// display only: the providers it hides are still polled, listed in the popup and notified about.
function barSegments(entries, mode, options) {
    var limit = number((options || {}).maxProviders);
    if (limit === null) limit = 2;
    return (limit > 0 ? entries.slice(0, limit) : entries).map(function(entry) {
            var segments = laneSegments(entry, mode, options);
            return {provider: entry.provider,
                tag: entry.provider === "codex" ? "CX" : entry.provider === "claude" ? "CL" : entry.provider,
                text: segments.length ? segments.join(" · ") : "—"};
        });
}

function summary(entries, mode) {
    var shown = barSegments(entries, mode);
    var label = shown.map(function(entry) { return entry.tag + " " + entry.text; }).join("  ·  ");
    return label + (entries.length > shown.length ? "  +" + (entries.length - shown.length) : "");
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

function providerName(id) {
    var names = {codex: "Codex", claude: "Claude", copilot: "GitHub Copilot", gemini: "Gemini",
        cursor: "Cursor", antigravity: "Antigravity", openrouter: "OpenRouter", kiro: "Kiro"};
    return names[id] || (id ? id.charAt(0).toUpperCase() + id.slice(1) : "Unknown provider");
}

function quotaValue(remaining, mode) { return mode === "used" ? 100 - remaining : remaining; }

function resetText(timestamp, now, mode) {
    var date = new Date(timestamp);
    if (!timestamp || !isFinite(date.getTime())) return "Reset time unavailable";
    var absolute = date.toLocaleString();
    if (mode === "absolute") return "Resets " + absolute;
    if (mode === "both") return resetLabel(timestamp, now) + " · " + absolute;
    return resetLabel(timestamp, now);
}
