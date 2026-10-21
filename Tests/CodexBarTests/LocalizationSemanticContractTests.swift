import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct LocalizationSemanticContractTests {
    @Test(arguments: [
        ("de", "API key or Cookie: …", "Schlüssel"),
        ("de", "ClawRouter spend", "Ausgaben"),
        ("es", "Rate limit", "solicitudes"),
        ("ja", "Stay Awake", "スリープ"),
        ("ja", "BY USAGE", "使用量"),
        ("fr", "%d DAYS", "%d JOURS"),
        ("ar", "Unmetered", "غير مُقاس"),
        ("fr", "Unmetered", "non mesurée"),
        ("pt-BR", "Unmetered", "não medido"),
        ("de", "Spend", "Ausgaben"),
        ("de", "Today spend", "Ausgaben"),
        ("ar", "Shared pool", "الحصة"),
        ("es", "Shared pool", "Cuota"),
        ("sv", "Plan", "Abonnemang"),
        ("id", "Cookie header or bare session value", "tanpa header"),
        ("fa", "Cookie header or bare session value", "بدون سرآیند"),
        ("id", "tab_menu", "Menu"),
        ("id", "refresh_manual", "Manual"),
        ("id", "Manual", "Manual"),
        ("id", "%dd ago", "hari"),
        ("it", "%d-DAY SPEND", "SU %d GIORNI"),
        ("ko", "Most usable account", "사용 가능량"),
        ("ja", "Today spend", "支出"),
        ("pl", "Priced", "z określoną ceną"),
        ("pl", "Unpriced", "bez określonej ceny"),
        ("sv", "Rate limit", "anropsfrekvens"),
        ("nl", "Optional project ID or slug. Leave blank for the default v0 scope.", "slug"),
        ("pt-BR", "codex_workspaces_tokens", "Tokens"),
        ("pt-BR", "tab_menu", "Menu"),
        ("nl", "Account", "Account"),
        ("vi", "Unpriced", "chưa có giá"),
        ("vi", "metric_mistral_payg", "theo mức sử dụng"),
        ("de", "Balance", "Guthaben"),
        ("tr", "API keys", "anahtarları"),
        ("tr", "Bank cap", "üst sınırı"),
        ("uk", "Routed", "Маршрутизовано"),
        ("ar", "CodexBar Switcher", "مبدّل"),
        ("tr", "Runs out in", "kalan süre"),
        ("th", "Sonnet", "Sonnet"),
        ("ar", "Workspace spend · 30d", "يومًا"),
        ("fa", "Extra usage balance", "موجودی"),
        ("ca", "Rate limit", "sol·licituds"),
        ("id", "Rate limit", "frekuensi"),
        ("pt-BR", "metric_mistral_payg", "conforme o uso"),
        ("ja", "Runs out", "見込み"),
        ("fr", "Runs out", "prévu"),
        ("nl", "Runs out", "Verwachte"),
        ("ar", "API est.", "تقدير"),
        ("nl", "Overage", "Meerverbruik"),
        ("th", "%@-hour limit", "ช่วง"),
        ("fa", "Paste a cURL capture from the ZoomMate AI credit usage page.", "دستور"),
        ("pl", "Credit balance from the Codebuff API", "Saldo kredytów"),
        ("th", "Raycast AI credits are a monthly allowance, not a cost history.", "จัดสรร"),
    ])
    func `technical translations retain their domain meaning`(language: String, key: String, term: String) {
        #expect(L(key, language: language).contains(term))
    }

    @Test(arguments: [("es", "Plan", "Plan"), ("pl", "codex_workspaces_model", "Model")])
    func `subscription and model labels use technical nouns`(language: String, key: String, expected: String) {
        #expect(L(key, language: language) == expected)
    }

    @Test
    func `billing warnings and authentication guidance preserve operational meaning`() {
        let billing = "AWS charges $0.01 per Cost Explorer request against the primary billing view. "
            + "A refresh can make multiple requests, and CloudWatch activity can add charges. "
            + "The displayed monthly budget does not cap AWS billing."
        #expect(L(billing, language: "ko").contains("AWS 청구액의 상한을 설정하지 않습니다"))
        let organization = "Optional for automatic auth. Use a slug, URL, or internal org-... / org_... ID. "
            + "Manual auth may need the x-cog-org-id header from a successful Devin quota request."
        #expect(L(organization, language: "tr").contains("slug"))
        let account = "Optional when the API key can access one account; CodexBar discovers it automatically. "
            + "For multiple accounts, find the slug in the app.fireworks.ai home account switcher "
            + "or run firectl whoami."
        for language in ["pl", "ru"] {
            #expect(L(account, language: language).contains("slug"))
        }
    }

    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func `credential examples preserve literal key prefixes`(language: AppLanguage) {
        let example = L("ark-... or AKLT...", language: language.rawValue)
        #expect(example.contains("ark-"))
        #expect(example.contains("AKLT"))
        let cookie = L("ory_session_…=…; csrftoken=…", language: language.rawValue)
        #expect(cookie.contains("ory_session_"))
        #expect(cookie.contains("csrftoken="))
        #expect(L("Sonnet", language: language.rawValue).contains("Sonnet"))
    }

    @Test(arguments: [
        ("in 2d", "di 2 hari"),
        ("in 2d 18h", "di 2 hari 18j"),
        ("in 2d 5m", "di 2 hari 5m"),
        ("in 18h", "di 18j"),
        ("in 18h 5m", "di 18j 5m"),
        ("in 5m", "di 5m"),
    ])
    func `Indonesian provider countdowns preserve distinct day hour and minute units`(
        countdown: String,
        expected: String) throws
    {
        try CodexBarLocalizationOverride.$appLanguage.withValue("id") {
            let details = try ProviderDetailSection(title: "Quota details", rows: [
                .init(label: "Period", value: "peak \(countdown)", secondaryValue: "off-peak \(countdown)"),
            ])
            let localized = UsageMenuCardView.Model.localizedProviderDetails([details], provider: .zai)
            let row = try #require(localized.first?.rows.first)
            #expect(row.value == "\(L("peak")) \(expected)")
            #expect(row.secondaryValue == "\(L("off-peak")) \(expected)")
        }
    }

    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func `login and recovery translations preserve executable commands`(language: AppLanguage) {
        #expect(L("vertex_ai_login_instructions", language: language.rawValue)
            .contains("gcloud auth application-default login"))
        let recovery = L("managed_login_failed", language: language.rawValue)
        #expect(recovery.contains("codex --version"))
        #expect(recovery.contains("npm install -g --include=optional @openai/codex@latest"))
    }

    private static let shortcutHelp = "These shortcuts work while the provider switcher menu is open. "
        + "Use ctrl, alt, shift and cmd with a letter, digit, left or right; use none to disable an action."

    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func `translated shortcut instructions preserve the parser grammar`(language: AppLanguage) throws {
        let help = L(Self.shortcutHelp, language: language.rawValue)
        for token in ["ctrl", "alt", "shift", "cmd", "left", "right", "none"] {
            #expect(
                help.range(of: "\\b\(token)\\b", options: .regularExpression) != nil,
                "Missing literal shortcut token \(token) in \(language.rawValue)")
        }
        // Exercise exactly the input described in the help, including both directional keys.
        #expect(try ProviderSwitcherShortcuts.normalized("ctrl+alt+shift+cmd+left") ==
            "ctrl+alt+shift+cmd+left")
        #expect(try ProviderSwitcherShortcuts.normalized("shift+right") == "shift+right")
        #expect(try ProviderSwitcherShortcuts.normalized("none") == "none")
    }

    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    func `Chutes credential placeholders retain the service and API names`(language: AppLanguage) {
        let placeholder = L("chutes key...", language: language.rawValue)
        #expect(placeholder.contains("Chutes"))
        #expect(placeholder.contains("API"))
    }

    @Test
    func `German Amp credit hint describes financial balances`() {
        let hint = L("Individual and workspace credit balances from Amp.", language: "de")
        #expect(hint.contains("Guthaben"))
        #expect(hint.contains("Arbeitsbereich"))
        #expect(hint.contains("Amp"))
        #expect(!hint.contains("Waagen"))
        #expect(!hint.contains("waagen"))
    }
}
