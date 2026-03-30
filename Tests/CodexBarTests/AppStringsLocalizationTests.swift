import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct AppStringsLocalizationTests {
    @Test
    func `selected language resolves localized strings and fallback`() {
        AppStrings.withTestingLanguage(.simplifiedChinese) {
            #expect(AppStrings.tr("General") == "通用")
            #expect(AppStrings.tr("Language") == "语言")
            #expect(AppStrings.tr("__missing_translation_key__") == "__missing_translation_key__")
        }

        AppStrings.withTestingLanguage(.traditionalChinese) {
            #expect(AppStrings.tr("General") == "一般")
            #expect(AppStrings.tr("Language") == "語言")
        }

        AppStrings.withTestingLanguage(.english) {
            #expect(AppStrings.tr("General") == "General")
            #expect(AppStrings.tr("Language") == "Language")
        }
    }

    @Test
    func `relative strings follow selected language`() {
        AppStrings.withTestingLanguage(.simplifiedChinese) {
            #expect(Date().relativeDescription(now: Date()) == "刚刚")
        }

        AppStrings.withTestingLanguage(.english) {
            #expect(Date().relativeDescription(now: Date()) == "just now")
        }
    }

    @Test
    func `month day formatting follows selected language`() throws {
        let date = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(
            year: 2025,
            month: 1,
            day: 5)))

        AppStrings.withTestingLanguage(.simplifiedChinese) {
            #expect(AppStrings.monthDayString(from: date).contains("月"))
        }

        AppStrings.withTestingLanguage(.english) {
            #expect(AppStrings.monthDayString(from: date).contains("Jan"))
        }
    }

    @Test
    func `status source and dashboard helpers localize simplified chinese`() {
        AppStrings.withTestingLanguage(.simplifiedChinese) {
            #expect(
                AppStrings.localizedProviderStatusDescription(
                    "Partially Degraded Service",
                    indicator: .minor) == "部分故障")
            #expect(AppStrings.localizedSourceLabel("web") == "网页")
            #expect(AppStrings.tr("Weekly") == "每周")
            #expect(AppStrings.tr("Monthly") == "每月")
            #expect(
                AppStrings.localizedOpenAIDashboardError(
                    "OpenAI dashboard data not found. Body sample: 跳至内容") ==
                    "未找到 OpenAI 仪表盘数据。页面片段：跳至内容")
        }
    }
}
