struct MiniMaxModelRemains: Decodable {
    let modelName: String?
    let currentIntervalTotalCount: Int?
    let currentIntervalUsageCount: Int?
    let startTime: Int?
    let endTime: Int?
    let remainsTime: Int?
    let intervalBoostPermille: Int?
    let currentIntervalRemainingPercent: Double?
    let currentIntervalStatus: Int?
    let currentWeeklyTotalCount: Int?
    let currentWeeklyUsageCount: Int?
    let weeklyStartTime: Int?
    let weeklyEndTime: Int?
    let weeklyRemainsTime: Int?
    let weeklyBoostPermille: Int?
    let currentWeeklyRemainingPercent: Double?
    let currentWeeklyStatus: Int?

    private enum CodingKeys: String, CodingKey {
        case modelName = "model_name"
        case currentIntervalTotalCount = "current_interval_total_count"
        case currentIntervalUsageCount = "current_interval_usage_count"
        case startTime = "start_time"
        case endTime = "end_time"
        case remainsTime = "remains_time"
        case intervalBoostPermille = "interval_boost_permill"
        case intervalBoostPermilleAlt = "interval_boost_permille"
        case currentIntervalRemainingPercent = "current_interval_remaining_percent"
        case currentIntervalStatus = "current_interval_status"
        case currentWeeklyTotalCount = "current_weekly_total_count"
        case currentWeeklyUsageCount = "current_weekly_usage_count"
        case weeklyStartTime = "weekly_start_time"
        case weeklyEndTime = "weekly_end_time"
        case weeklyRemainsTime = "weekly_remains_time"
        case weeklyBoostPermille = "weekly_boost_permill"
        case weeklyBoostPermilleAlt = "weekly_boost_permille"
        case currentWeeklyRemainingPercent = "current_weekly_remaining_percent"
        case currentWeeklyStatus = "current_weekly_status"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        self.currentIntervalTotalCount = MiniMaxDecoding.decodeInt(container, forKey: .currentIntervalTotalCount)
        self.currentIntervalUsageCount = MiniMaxDecoding.decodeInt(container, forKey: .currentIntervalUsageCount)
        self.startTime = MiniMaxDecoding.decodeInt(container, forKey: .startTime)
        self.endTime = MiniMaxDecoding.decodeInt(container, forKey: .endTime)
        self.remainsTime = MiniMaxDecoding.decodeInt(container, forKey: .remainsTime)
        self.intervalBoostPermille = MiniMaxDecoding.decodeInt(container, forKey: .intervalBoostPermille)
            ?? MiniMaxDecoding.decodeInt(container, forKey: .intervalBoostPermilleAlt)
        self.currentIntervalRemainingPercent = MiniMaxDecoding.decodeDouble(
            container,
            forKey: .currentIntervalRemainingPercent)
        self.currentIntervalStatus = MiniMaxDecoding.decodeInt(container, forKey: .currentIntervalStatus)
        self.currentWeeklyTotalCount = MiniMaxDecoding.decodeInt(container, forKey: .currentWeeklyTotalCount)
        self.currentWeeklyUsageCount = MiniMaxDecoding.decodeInt(container, forKey: .currentWeeklyUsageCount)
        self.weeklyStartTime = MiniMaxDecoding.decodeInt(container, forKey: .weeklyStartTime)
        self.weeklyEndTime = MiniMaxDecoding.decodeInt(container, forKey: .weeklyEndTime)
        self.weeklyRemainsTime = MiniMaxDecoding.decodeInt(container, forKey: .weeklyRemainsTime)
        self.weeklyBoostPermille = MiniMaxDecoding.decodeInt(container, forKey: .weeklyBoostPermille)
            ?? MiniMaxDecoding.decodeInt(container, forKey: .weeklyBoostPermilleAlt)
        self.currentWeeklyRemainingPercent = MiniMaxDecoding.decodeDouble(
            container,
            forKey: .currentWeeklyRemainingPercent)
        self.currentWeeklyStatus = MiniMaxDecoding.decodeInt(container, forKey: .currentWeeklyStatus)
    }
}
