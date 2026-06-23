namespace CodexBarTray;

// Windows port of the macOS quota-notification logic
// (Sources/CodexBar/SessionQuotaNotifications.swift). The decision logic lives in
// the macOS app layer on top of UsageSnapshot data; on Windows the equivalent
// data arrives as parsed /usage results, so we re-implement the same pure logic
// here and drive Windows balloon notifications from it.

public enum SessionTransition
{
    None,
    Depleted,
    Restored,
}

public enum QuotaWindowKind
{
    Session,
    Weekly,
}

/// <summary>A notification ready to be shown to the user.</summary>
public sealed record NotificationItem(string Title, string Body, bool IsWarning);

/// <summary>User-controlled notification preferences (persisted in <see cref="UiSettings"/>).</summary>
public sealed record NotificationPrefs(bool SessionEnabled, bool WarningEnabled, IReadOnlyList<int> Thresholds);

/// <summary>Threshold sanitation, mirroring core <c>QuotaWarningThresholds</c>.</summary>
public static class QuotaThresholds
{
    public static readonly int[] Defaults = { 50, 20 };
    public const int Min = 0;
    public const int Max = 99;

    public static int Clamp(int value) => Math.Min(Math.Max(value, Min), Max);

    public static List<int> Sanitized(IEnumerable<int>? raw)
    {
        var list = raw?.ToList() ?? new List<int>();
        if (list.Count == 0) return Defaults.ToList();
        var unique = list.Select(Clamp).Distinct().OrderByDescending(v => v).ToList();
        return unique.Count == 0 ? Defaults.ToList() : unique;
    }

    public static List<int> Active(IEnumerable<int>? raw) =>
        Sanitized(raw).Where(v => v > 0).ToList();
}

/// <summary>Session depleted/restored transitions, mirroring core SessionQuotaNotificationLogic.</summary>
public static class SessionQuotaLogic
{
    public const double DepletedThreshold = 0.0001;

    public static bool IsDepleted(double? remaining) =>
        remaining is { } value && value <= DepletedThreshold;

    public static SessionTransition Transition(double? previousRemaining, double? currentRemaining)
    {
        if (currentRemaining is not { } current || previousRemaining is not { } previous)
            return SessionTransition.None;

        var wasDepleted = previous <= DepletedThreshold;
        var isDepleted = current <= DepletedThreshold;

        if (!wasDepleted && isDepleted) return SessionTransition.Depleted;
        if (wasDepleted && !isDepleted) return SessionTransition.Restored;
        return SessionTransition.None;
    }
}

/// <summary>Threshold-crossing detection, mirroring core QuotaWarningNotificationLogic.</summary>
public static class QuotaWarningLogic
{
    public static int? CrossedThreshold(
        double? previousRemaining,
        double currentRemaining,
        IReadOnlyList<int> thresholds,
        ISet<int> alreadyFired)
    {
        var sanitized = QuotaThresholds.Active(thresholds);
        var eligible = sanitized
            .Where(t => currentRemaining <= t && !alreadyFired.Contains(t))
            .ToList();
        if (eligible.Count == 0) return null;

        if (previousRemaining is { } previous)
        {
            var crossed = eligible.Where(t => previous > t).ToList();
            return crossed.Count == 0 ? null : crossed.Min();
        }

        return eligible.Min();
    }

    public static HashSet<int> FiredThresholdsAfterWarning(int threshold, IReadOnlyList<int> thresholds) =>
        QuotaThresholds.Active(thresholds).Where(t => t >= threshold).ToHashSet();

    public static HashSet<int> ThresholdsToClear(double currentRemaining, ISet<int> alreadyFired) =>
        alreadyFired.Where(t => currentRemaining > t).ToHashSet();
}

/// <summary>Notification copy, ported from en.lproj/Localizable.strings (the tray is English-only for now).</summary>
public static class NotificationCopy
{
    public static (string Title, string Body) Session(SessionTransition transition, string providerName) => transition switch
    {
        SessionTransition.Depleted => (
            $"{providerName} session depleted",
            "0% left. Will notify when it's available again."),
        SessionTransition.Restored => (
            $"{providerName} session restored",
            "Session quota is available again."),
        _ => ("", ""),
    };

    public static (string Title, string Body) Warning(
        string providerName,
        QuotaWindowKind window,
        int threshold,
        double currentRemaining,
        string? account)
    {
        var windowLabel = window == QuotaWindowKind.Session ? "session" : "weekly";
        var remainingText = $"{(int)Math.Round(Math.Clamp(currentRemaining, 0, 100))}%";
        var title = $"{providerName} {windowLabel} quota low";
        var body = account is { Length: > 0 }
            ? $"Account {account}. {remainingText} left. Reached your {threshold}% {windowLabel} warning threshold."
            : $"{remainingText} left. Reached your {threshold}% {windowLabel} warning threshold.";
        return (title, body);
    }
}
