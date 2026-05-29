import Foundation
import Testing

@Suite
struct ColdStartValidationCheckerTests {
    @Test
    func `checker accepts complete non-placeholder fixture`() throws {
        let fixture = try Self.makeValidFixture()

        let result = try Self.runChecker(fixture)

        #expect(result.exitCode == 0)
        #expect(result.output.contains("OK: cold-start validation proves first-after-boot menu readiness"))
    }

    @Test
    func `checker fails when Cost submenu is placeholder only`() throws {
        let fixture = try Self.makeValidFixture()
        try Self.write(
            """
            Cost | submenu=true
            Cost submenu item count=1
            Cost submenu item 1: No data available | submenu=false
            Cost submenu bounds=10,10,120,80
            """,
            to: fixture.appendingPathComponent("settled-cost-submenu-ax.txt"))

        let result = try Self.runChecker(fixture)

        #expect(result.exitCode != 0)
        #expect(result.output.contains("No data available"))
    }

    @Test
    func `checker fails when immediate parent menu is partial`() throws {
        let fixture = try Self.makeValidFixture()
        try Self.write("partial\n", to: fixture.appendingPathComponent("immediate-parent-menu-status.txt"))

        let result = try Self.runChecker(fixture)

        #expect(result.exitCode != 0)
        #expect(result.output.contains("Immediate first-open parent menu was not complete"))
    }

    private static func runChecker(_ fixture: URL) throws -> (exitCode: Int32, output: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = root.appendingPathComponent("Scripts/check_cold_start_validation_result.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, fixture.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func makeValidFixture() throws -> URL {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent(
            "codexbar-cold-start-checker-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)

        try self.write(
            """
            phase=before-launch
            run_id=test
            app_path=/tmp/CodexBar.app
            boot_epoch=1760000000
            boot_time_utc=2026-05-26T00:00:00Z
            metadata_written_at_utc=2026-05-26T00:05:19Z
            uptime_seconds=319
            post_boot_max_uptime_seconds=900
            existing_codexbar_process_count=0
            post_boot_first_launch_candidate=true
            """,
            to: fixture.appendingPathComponent("boot-session-metadata.txt"))
        try self.write(
            """
            run_id=test
            metadata_written_at_utc=2026-05-26T00:05:19Z
            app_path=/tmp/CodexBar.app
            app_executable=/tmp/CodexBar.app/Contents/MacOS/CodexBar
            app_binary_sha256=app-sha
            validator_script_sha256=validator-sha
            checker_script_sha256=checker-sha
            bundle_identifier=com.example.CodexBar
            bundle_short_version=0.0.0
            bundle_version=0
            codex_build_timestamp=
            codex_git_commit=
            """,
            to: fixture.appendingPathComponent("app-bundle-metadata.txt"))
        try self.write(
            """
            run_id=test
            app_path=/tmp/CodexBar.app
            metadata_written_at_utc=2026-05-26T00:05:19Z
            login_items=
            login_item_app_path=/Applications/CodexBar.app
            login_item_app_sha256=
            codexbar_login_item_present=false
            running_codexbar_process_count=0
            """,
            to: fixture.appendingPathComponent("login-context.txt"))
        try self.write(
            """
            run_id=test
            app_path=/tmp/CodexBar.app
            pid=123
            process_path=/tmp/CodexBar.app/Contents/MacOS/CodexBar
            process_lstart=Tue May 26 00:05:19 2026
            started_at=2026-05-26T00:05:19Z
            settle_seconds=20
            post_boot_first_launch_candidate=true
            manual_refresh_used=false
            tab_switch_used=false
            menu_reopen_required_for_parent=false
            menu_reopen_required_for_cost=false
            manual_recovery_used=false
            """,
            to: fixture.appendingPathComponent("run-metadata.txt"))
        try self.write("complete\n", to: fixture.appendingPathComponent("immediate-parent-menu-status.txt"))
        try self.write(self.parentAX, to: fixture.appendingPathComponent("immediate-parent-menu-ax.txt"))
        try self.write(self.parentAX, to: fixture.appendingPathComponent("settled-parent-menu-ax.txt"))
        try self.write(
            """
            Cost | submenu=true
            Cost submenu item count=1
            Cost submenu item 1: Cost chart | submenu=false
            Cost submenu bounds=10,10,120,80
            """,
            to: fixture.appendingPathComponent("settled-cost-submenu-ax.txt"))
        try self.write(
            """
            python_executable=/usr/bin/python3
            python_version=3.11.0
            image_decoder=stdlib_png
            immediate_parent_width=400
            immediate_parent_height=600
            immediate_parent_bounds_found=true
            settled_parent_width=400
            settled_parent_height=600
            settled_parent_bounds_found=true
            cost_submenu_width=200
            cost_submenu_height=120
            cost_submenu_bounds_found=true
            immediate_parent_gold_pixels=1
            settled_parent_gold_pixels=1
            cost_submenu_aqua_pixels=1
            cost_submenu_item_count=1
            """,
            to: fixture.appendingPathComponent("visual-readiness.txt"))
        try self.write(
            """
            app_opened_epoch_ms=1000
            app_opened_at_utc=2026-05-26T00:05:19.000Z
            menu_extra_ready_epoch_ms=1500
            menu_extra_ready_at_utc=2026-05-26T00:05:19.500Z
            immediate_parent_opened_epoch_ms=1600
            immediate_parent_opened_at_utc=2026-05-26T00:05:19.600Z
            immediate_parent_ax_captured_epoch_ms=2500
            immediate_parent_ax_captured_at_utc=2026-05-26T00:05:20.500Z
            cost_submenu_opened_epoch_ms=3000
            cost_submenu_opened_at_utc=2026-05-26T00:05:21.000Z
            cost_submenu_ax_captured_epoch_ms=4500
            cost_submenu_ax_captured_at_utc=2026-05-26T00:05:22.500Z
            menu_extra_ready_ms_after_launch=500
            immediate_parent_capture_ms_after_launch=1500
            cost_submenu_capture_ms_after_launch=3500
            immediate_parent_ax_capture_ms_after_open=900
            cost_submenu_ax_capture_ms_after_open=1500
            """,
            to: fixture.appendingPathComponent("timing-metadata.txt"))
        try self.write(self.validManifest, to: fixture.appendingPathComponent("cold-start-proof-manifest.json"))

        return fixture
    }

    private static let parentAX = """
    Menu bounds=0,0,400,600
    1: Codex | submenu=false
    2: Buy Credits... | submenu=false
    3: Cost | submenu=true
    4: Usage Dashboard | submenu=false
    5: Status Page | submenu=false
    6: Refresh | submenu=false
    """

    private static let validManifest = """
    {
      "app_binary_sha256": "app-sha",
      "app_path": "/tmp/CodexBar.app",
      "boot_time_utc": "2026-05-26T00:00:00Z",
      "checker_sha256": "checker-sha",
      "existing_codexbar_process_count": 0,
      "first_launch_uncontested": true,
      "first_open_cost_submenu": {
        "ax_path": "settled-cost-submenu-ax.txt",
        "hosted_content_present": true,
        "item_count": 1,
        "opened": true,
        "placeholder_only": false,
        "provider": "codex",
        "represented_object": "costHistoryChart",
        "screenshot_path": "settled-codex-cost-submenu.png"
      },
      "first_open_parent": {
        "ax_path": "immediate-parent-menu-ax.txt",
        "captured_at_ms_after_launch": 1500,
        "menu_bounds_found": true,
        "missing_rows": [],
        "required_rows_present": true,
        "screenshot_path": "immediate-codex-parent-menu.png",
        "status": "complete",
        "unexpected_placeholders": []
      },
      "git_head": "test",
      "late_data_refresh": {
        "hosted_submenu_rebuilt_without_manual_action": true,
        "max_refresh_latency_ms": 3500,
        "parent_refresh_without_manual_action": true
      },
      "login_item_present_at_runner_start": false,
      "schema": 1,
      "uptime_seconds": 319,
      "validator_sha256": "validator-sha"
    }
    """

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
