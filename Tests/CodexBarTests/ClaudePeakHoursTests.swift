import CodexBarCore
import Foundation
import Testing

struct ClaudePeakHoursTests {
    private static let eastern = TimeZone(identifier: "America/New_York")!

    private func date(
        year: Int = 2026,
        month: Int = 3,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.eastern
        return cal.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute))!
    }

    // MARK: - Weekday peak hours

    @Test
    func weekdayMorningBeforePeak() {
        // Wednesday 2026-03-25 at 7:00 AM ET → off-peak, 1h until peak
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 7))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 1h")
    }

    @Test
    func weekdayJustBeforePeak() {
        // Wednesday 2026-03-25 at 7:45 AM ET → off-peak, 15m until peak
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 7, minute: 45))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 15m")
    }

    @Test
    func weekdayPeakStart() {
        // Wednesday 2026-03-25 at 8:00 AM ET → peak, 6h remaining
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 8))
        #expect(status.isPeak)
        #expect(status.label == "Peak · ends in 6h")
    }

    @Test
    func weekdayMidPeak() {
        // Wednesday 2026-03-25 at 11:30 AM ET → peak, 2h 30m remaining
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 11, minute: 30))
        #expect(status.isPeak)
        #expect(status.label == "Peak · ends in 2h 30m")
    }

    @Test
    func weekdayPeakEndBoundary() {
        // Wednesday 2026-03-25 at 1:59 PM ET → peak, 1m remaining
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 13, minute: 59))
        #expect(status.isPeak)
        #expect(status.label == "Peak · ends in 1m")
    }

    @Test
    func weekdayAfterPeak() {
        // Wednesday 2026-03-25 at 2:00 PM ET → off-peak, next peak tomorrow 8 AM (18h)
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 14))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 18h")
    }

    @Test
    func weekdayLateEvening() {
        // Thursday 2026-03-26 at 11 PM ET → off-peak, 9h until next peak
        let status = ClaudePeakHours.status(at: self.date(day: 26, hour: 23))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 9h")
    }

    // MARK: - Weekend

    @Test
    func saturdayMorning() {
        // Saturday 2026-03-28 at 10 AM ET → off-peak, ~46h until Monday 8 AM
        let status = ClaudePeakHours.status(at: self.date(day: 28, hour: 10))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 46h")
    }

    @Test
    func sundayEvening() {
        // Sunday 2026-03-22 at 9 PM ET → off-peak, 11h until Monday 8 AM
        let status = ClaudePeakHours.status(at: self.date(day: 22, hour: 21))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 11h")
    }

    // MARK: - Friday → Monday transition

    @Test
    func fridayAfterPeak() {
        // Friday 2026-03-27 at 3 PM ET → off-peak, next peak Monday 8 AM (65h)
        let status = ClaudePeakHours.status(at: self.date(day: 27, hour: 15))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 65h")
    }

    @Test
    func fridayPeak() {
        // Friday 2026-03-27 at 12 PM ET → peak, 2h remaining
        let status = ClaudePeakHours.status(at: self.date(day: 27, hour: 12))
        #expect(status.isPeak)
        #expect(status.label == "Peak · ends in 2h")
    }

    // MARK: - Edge cases

    @Test
    func mondayMidnight() {
        // Monday 2026-03-23 at 12:00 AM ET → off-peak, 8h until peak
        let status = ClaudePeakHours.status(at: self.date(day: 23, hour: 0))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 8h")
    }

    @Test
    func peakWithMinuteGranularity() {
        // Wednesday 2026-03-25 at 12:15 PM ET → peak, 1h 45m remaining
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 12, minute: 15))
        #expect(status.isPeak)
        #expect(status.label == "Peak · ends in 1h 45m")
    }

    @Test
    func saturdayMidnight() {
        // Saturday 2026-03-28 at 12:00 AM ET → off-peak, 56h until Monday 8 AM
        let status = ClaudePeakHours.status(at: self.date(day: 28, hour: 0))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 56h")
    }
}
