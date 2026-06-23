namespace CodexBarTray;

/// <summary>
/// Stateful evaluator that turns each /usage refresh into notification events,
/// mirroring the macOS UsageStore quota-notification orchestration
/// (handleSessionQuotaTransition + handleQuotaWarningTransitions).
///
/// State (last-seen remaining, already-fired thresholds) is kept in memory for
/// the process lifetime, exactly like the macOS app — so on launch a provider
/// that is already below a threshold will surface one reminder.
///
/// Simplifications vs. macOS (acceptable for the first port, documented as TODO):
///  - Session window = primary (Copilot falls back to secondary); no Antigravity
///    quota-summary windows or window-source tracking.
///  - Weekly window = secondary.
///  - MiMo is excluded (no session/weekly semantics), matching macOS.
/// </summary>
public sealed class QuotaNotificationCoordinator
{
    private sealed class WarningState
    {
        public double? LastRemaining;
        public readonly HashSet<int> Fired = new();
    }

    private readonly Dictionary<string, double> _sessionRemaining = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<(string Provider, QuotaWindowKind Window), WarningState> _warningState = new();

    public IReadOnlyList<NotificationItem> Evaluate(IEnumerable<ProviderResult> results, NotificationPrefs prefs)
    {
        var items = new List<NotificationItem>();
        foreach (var result in results)
        {
            if (result.Error is not null) continue;
            var id = result.Provider;
            if (string.IsNullOrEmpty(id)) continue;
            if (IsMiMo(id)) continue;

            var name = UsageViewModelBuilder.DisplayName(id);
            var account = AccountName(result);

            EvaluateSession(items, id, name, result.Usage, prefs);
            EvaluateWarning(items, id, name, QuotaWindowKind.Session, result.Usage?.Primary, account, prefs);
            EvaluateWarning(items, id, name, QuotaWindowKind.Weekly, result.Usage?.Secondary, account, prefs);
        }
        return items;
    }

    private void EvaluateSession(
        List<NotificationItem> items,
        string id,
        string name,
        UsageData? usage,
        NotificationPrefs prefs)
    {
        var window = SessionWindow(id, usage);
        if (window is null)
        {
            _sessionRemaining.Remove(id);
            return;
        }

        var current = Remaining(window);
        var hadPrevious = _sessionRemaining.TryGetValue(id, out var previous);

        try
        {
            if (!prefs.SessionEnabled) return;

            // First observation this run: only announce an already-depleted session,
            // never a "restored" we never saw deplete (matches macOS).
            if (!hadPrevious)
            {
                if (SessionQuotaLogic.IsDepleted(current))
                    Add(items, NotificationCopy.Session(SessionTransition.Depleted, name), isWarning: true);
                return;
            }

            var transition = SessionQuotaLogic.Transition(previous, current);
            if (transition == SessionTransition.None) return;

            Add(items, NotificationCopy.Session(transition, name), isWarning: transition == SessionTransition.Depleted);
        }
        finally
        {
            // Record the latest remaining even when notifications are disabled, so
            // re-enabling them does not replay a stale transition.
            _sessionRemaining[id] = current;
        }
    }

    private void EvaluateWarning(
        List<NotificationItem> items,
        string id,
        string name,
        QuotaWindowKind windowKind,
        RateWindow? rateWindow,
        string? account,
        NotificationPrefs prefs)
    {
        if (!prefs.WarningEnabled) return;

        var key = (id, windowKind);
        if (rateWindow is null)
        {
            _warningState.Remove(key);
            return;
        }

        var current = Remaining(rateWindow);
        if (!_warningState.TryGetValue(key, out var state))
        {
            state = new WarningState();
            _warningState[key] = state;
        }

        // Re-arm thresholds the window has since recovered above.
        foreach (var cleared in QuotaWarningLogic.ThresholdsToClear(current, state.Fired))
            state.Fired.Remove(cleared);

        var crossed = QuotaWarningLogic.CrossedThreshold(state.LastRemaining, current, prefs.Thresholds, state.Fired);
        if (crossed is { } threshold)
        {
            foreach (var fired in QuotaWarningLogic.FiredThresholdsAfterWarning(threshold, prefs.Thresholds))
                state.Fired.Add(fired);
            Add(items, NotificationCopy.Warning(name, windowKind, threshold, current, account), isWarning: true);
        }

        state.LastRemaining = current;
    }

    private static RateWindow? SessionWindow(string id, UsageData? usage)
    {
        if (usage is null) return null;
        if (usage.Primary is { } primary) return primary;
        // Copilot free plans can expose only chat quota; fall back to secondary.
        if (string.Equals(id, "copilot", StringComparison.OrdinalIgnoreCase) && usage.Secondary is { } secondary)
            return secondary;
        return null;
    }

    private static double Remaining(RateWindow window) => Math.Clamp(100.0 - window.UsedPercent, 0, 100);

    private static string? AccountName(ProviderResult result)
    {
        var account = (result.Usage?.Identity?.AccountEmail ?? result.Account)?.Trim();
        return string.IsNullOrEmpty(account) ? null : account;
    }

    private static bool IsMiMo(string id) => string.Equals(id, "mimo", StringComparison.OrdinalIgnoreCase);

    private static void Add(List<NotificationItem> items, (string Title, string Body) copy, bool isWarning)
    {
        if (string.IsNullOrEmpty(copy.Title)) return;
        items.Add(new NotificationItem(copy.Title, copy.Body, isWarning));
    }
}
