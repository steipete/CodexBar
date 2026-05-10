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
        minute: Int = 0,
        second: Int = 0) -> Date
    {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.eastern
        return cal.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second))!
    }

    @Test
    func `weekday morning before peak`() {
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 7))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 1h")
    }

    @Test
    func `weekday just before peak`() {
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 7, minute: 45))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 15m")
    }

    @Test
    func `weekday peak start`() {
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 8))
        #expect(status.isPeak)
        #expect(status.label == "Peak · ends in 6h")
    }

    @Test
    func `weekday mid peak`() {
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 11, minute: 30))
        #expect(status.isPeak)
        #expect(status.label == "Peak · ends in 2h 30m")
    }

    @Test
    func `weekday peak end boundary`() {
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 13, minute: 59))
        #expect(status.isPeak)
        #expect(status.label == "Peak · ends in 1m")
    }

    @Test
    func `weekday after peak`() {
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 14))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 18h")
    }

    @Test
    func `weekday late evening`() {
        let status = ClaudePeakHours.status(at: self.date(day: 26, hour: 23))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 9h")
    }

    @Test
    func `saturday morning`() {
        let status = ClaudePeakHours.status(at: self.date(day: 28, hour: 10))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 46h")
    }

    @Test
    func `sunday evening`() {
        let status = ClaudePeakHours.status(at: self.date(day: 29, hour: 21))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 11h")
    }

    @Test
    func `friday after peak`() {
        let status = ClaudePeakHours.status(at: self.date(day: 27, hour: 15))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 65h")
    }

    @Test
    func `friday peak`() {
        let status = ClaudePeakHours.status(at: self.date(day: 27, hour: 12))
        #expect(status.isPeak)
        #expect(status.label == "Peak · ends in 2h")
    }

    @Test
    func `spring forward weekend`() {
        let status = ClaudePeakHours.status(at: self.date(day: 7, hour: 10))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 45h")
    }

    @Test
    func `monday midnight`() {
        let status = ClaudePeakHours.status(at: self.date(day: 23, hour: 0))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 8h")
    }

    @Test
    func `peak with minute granularity`() {
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 12, minute: 15))
        #expect(status.isPeak)
        #expect(status.label == "Peak · ends in 1h 45m")
    }

    @Test
    func `saturday midnight`() {
        let status = ClaudePeakHours.status(at: self.date(day: 28, hour: 0))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 56h")
    }

    @Test
    func `weekday just before peak with seconds`() {
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 7, minute: 45, second: 30))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 15m")
    }

    @Test
    func `weekday one minute before peak with seconds`() {
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 7, minute: 59, second: 30))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 1m")
    }

    @Test
    func `weekday last second before peak`() {
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 7, minute: 59, second: 59))
        #expect(!status.isPeak)
        #expect(status.label == "Off-peak · peak in 1m")
    }

    @Test
    func `weekday peak start with seconds`() {
        let status = ClaudePeakHours.status(at: self.date(day: 25, hour: 8, minute: 0, second: 30))
        #expect(status.isPeak)
        #expect(status.label == "Peak · ends in 6h")
    }
}
