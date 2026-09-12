// In-memory transitions only: never notify on startup, errors, or ambiguous accounts.
function transition(previous, entries, threshold) {
    var limit = Math.max(1, Math.min(99, Number(threshold) || 10));
    var counts = {};
    entries.forEach(function(row) { counts[row.provider] = (counts[row.provider] || 0) + 1; });
    var next = {};
    var events = [];
    entries.forEach(function(row) {
        if (counts[row.provider] !== 1 || row.failed) return;
        row.windows.forEach(function(window) {
            var key = row.provider + "/" + window.key;
            var old = previous[key];
            next[key] = {remaining: window.remaining, reset: window.resetsAt};
            if (!old) return;
            if (old.remaining > limit && window.remaining <= limit) {
                events.push({kind: "low", provider: row.provider,
                    message: window.label + ": " + window.remaining + "% quota remaining."});
            } else if (old.reset && window.resetsAt && old.reset !== window.resetsAt && window.remaining > old.remaining) {
                events.push({kind: "reset", provider: row.provider,
                    message: window.label + " quota reset · " + window.remaining + "% remaining."});
            }
        });
        var level = row.statusLevel;
        if (["none", "minor", "major", "critical", "maintenance"].indexOf(level) !== -1) {
            var key = row.provider + "/status";
            var old = previous[key];
            next[key] = {level: level};
            if (old && old.level !== level) {
                if (level === "none") events.push({kind: "status", provider: row.provider, message: "Service has recovered."});
                else events.push({kind: "status", provider: row.provider, message: "Service status changed: " + level + "."});
            }
        }
    });
    return {state: next, events: events};
}

function summary(entries) {
    return entries.map(function(row) {
        var text = row.provider.toUpperCase();
        row.windows.forEach(function(window) { text += "\n" + window.label + ": " + window.remaining + "% remaining"; });
        if (row.error) text += "\n" + row.error;
        return text;
    }).join("\n\n");
}
