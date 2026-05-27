import CodexBarCore
import Foundation

// ProviderSubscriptionReminderType and ProviderSubscriptionReminderState are defined in
// CodexBarCore/ProviderSubscriptionReminderState.swift

struct ProviderSubscriptionReminderEvent: Equatable, Sendable {
    let type: ProviderSubscriptionReminderType
    let title: String
    let body: String
    let idSuffix: String
}

enum ProviderSubscriptionReminderLogic {
    static func evaluate(
        providerName: String,
        snapshot: ProviderSubscriptionSnapshot?,
        previous: ProviderSubscriptionReminderState?,
        now: Date = .init(),
        calendar: Calendar = .current)
        -> (state: ProviderSubscriptionReminderState?, events: [ProviderSubscriptionReminderEvent])
    {
        guard let snapshot else {
            return (nil, [])
        }

        let fingerprint = Self.fingerprint(snapshot: snapshot)
        var state = if let previous, previous.fingerprint == fingerprint {
            previous
        } else {
            ProviderSubscriptionReminderState(fingerprint: fingerprint, fired: [])
        }

        var events: [ProviderSubscriptionReminderEvent] = []
        let planText = snapshot.planName.map { " (\($0))" } ?? ""
        let titleBase = "\(providerName) subscription\(planText)"
        let context = ReminderContext(titleBase: titleBase, now: now, calendar: calendar)

        Self.appendRenewalEvent(
            snapshot: snapshot,
            state: &state,
            events: &events,
            context: context)
        Self.appendExpirationEvent(
            snapshot: snapshot,
            state: &state,
            events: &events,
            context: context)

        return (state, events)
    }

    private static func appendRenewalEvent(
        snapshot: ProviderSubscriptionSnapshot,
        state: inout ProviderSubscriptionReminderState,
        events: inout [ProviderSubscriptionReminderEvent],
        context: ReminderContext)
    {
        guard let renewsAt = snapshot.subscriptionRenewsAt else { return }
        guard snapshot.status == .active || snapshot.status == .trialing else { return }

        let dayDelta = Self.dayDelta(from: context.now, to: renewsAt, calendar: context.calendar)
        guard let type = Self.renewalType(dayDelta: dayDelta) else { return }
        guard !state.fired.contains(type) else { return }

        let dayLabel = dayDelta == 1 ? "day" : "days"
        let body = dayDelta == 0 ? "Renews today." : "Renews in \(dayDelta) \(dayLabel)."
        events.append(ProviderSubscriptionReminderEvent(
            type: type,
            title: context.titleBase,
            body: body,
            idSuffix: "renew-\(dayDelta)"))
        state.fired.insert(type)
    }

    private static func appendExpirationEvent(
        snapshot: ProviderSubscriptionSnapshot,
        state: inout ProviderSubscriptionReminderState,
        events: inout [ProviderSubscriptionReminderEvent],
        context: ReminderContext)
    {
        guard let expiresAt = snapshot.subscriptionExpiresAt else { return }

        let dayDelta = Self.dayDelta(from: context.now, to: expiresAt, calendar: context.calendar)
        guard let type = Self.expirationType(dayDelta: dayDelta) else { return }
        guard !state.fired.contains(type) else { return }

        let body: String
        if dayDelta < 0 {
            body = "Expired."
        } else if dayDelta == 0 {
            body = "Expires today."
        } else {
            let dayLabel = dayDelta == 1 ? "day" : "days"
            body = "Expires in \(dayDelta) \(dayLabel)."
        }
        events.append(ProviderSubscriptionReminderEvent(
            type: type,
            title: context.titleBase,
            body: body,
            idSuffix: dayDelta < 0 ? "expired" : "expire-\(dayDelta)"))
        state.fired.insert(type)
    }

    private struct ReminderContext {
        let titleBase: String
        let now: Date
        let calendar: Calendar
    }

    private static func renewalType(dayDelta: Int) -> ProviderSubscriptionReminderType? {
        if dayDelta == 0 {
            return .renewsToday
        }
        switch dayDelta {
        case 30: return .renewsIn30Days
        case 7: return .renewsIn7Days
        case 3: return .renewsIn3Days
        case 1: return .renewsIn1Day
        default: return nil
        }
    }

    private static func expirationType(dayDelta: Int) -> ProviderSubscriptionReminderType? {
        if dayDelta < 0 {
            return .expired
        }
        if dayDelta == 0 {
            return .expiresToday
        }
        switch dayDelta {
        case 30: return .expiresIn30Days
        case 7: return .expiresIn7Days
        case 3: return .expiresIn3Days
        case 1: return .expiresIn1Day
        default: return nil
        }
    }

    private static func fingerprint(snapshot: ProviderSubscriptionSnapshot) -> String {
        let renew = Self.dayOnlyTimestamp(snapshot.subscriptionRenewsAt)
        let expire = Self.dayOnlyTimestamp(snapshot.subscriptionExpiresAt)
        return [
            snapshot.provider.rawValue,
            snapshot.status.rawValue,
            snapshot.planName ?? "",
            renew,
            expire,
            snapshot.source.rawValue,
            snapshot.confidence.rawValue,
        ].joined(separator: "|")
    }

    private static func dayOnlyTimestamp(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let midnight = Calendar(identifier: .iso8601).startOfDay(for: date)
        return midnight.timeIntervalSince1970.description
    }

    private static func dayDelta(from now: Date, to date: Date, calendar: Calendar) -> Int {
        let startNow = calendar.startOfDay(for: now)
        let startDate = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: startNow, to: startDate).day ?? 0
    }
}
