import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml" as Desktop

TestCase {
    id: testCase
    name: "FloatingGauge"
    when: windowShown

    function defaults() {
        return {showFloating: true, floatingCompact: true, floatingOnTop: true,
            floatingProviders: [], floatingWidth: 360, floatingHeight: 440,
            showIdentity: false, quotaDisplay: "remaining", resetDisplay: "countdown",
            warningColors: true, notifyThreshold: 10};
    }
    function entry(provider, remaining, accountNumber) {
        return {provider: provider, accountNumber: accountNumber || 1, accountLabel: "private@example.invalid",
            windows: [{label: "Session", remaining: remaining, resetsAt: new Date(Date.now() + 7200000).toISOString()}],
            failed: false, error: "", credits: null};
    }
    QtObject {
        id: desktop
        property var settings: testCase.defaults()
        property var entries: []
        property bool busy: false
        property bool stale: false
        property string error: ""
        property string configError: ""
        property string updated: "12:00"
        property int refreshCount: 0
        property int geometryWrites: 0
        property int menuRequests: 0
        signal changed()
        signal floatingActionRequested(string action)
        function saveSettings(changes) {
            var next = Object.assign({}, settings, changes);
            settings = next;
            return true;
        }
        function refresh() { refreshCount++; }
        function showWindow(page) {}
        function showFloatingMenu(window) { menuRequests++; }
        function floatingAvailableWidth(window) { return 1280; }
        function restoreFloatingGeometry(window) {}
        function saveFloatingGeometry(window) {
            geometryWrites++;
            if (!settings.floatingCompact)
                return saveSettings({floatingWidth: window.width, floatingHeight: window.height});
            return true;
        }
    }
    Component { id: gaugeComponent; Desktop.FloatingGauge {} }
    property var gauge: null

    function textItem(item, text) {
        if (item.text === text && item.visible) return item;
        for (var i = 0; i < item.children.length; ++i) {
            var found = textItem(item.children[i], text);
            if (found) return found;
        }
        return null;
    }
    function shown(text) { return textItem(gauge.contentItem, text) !== null; }
    function init() {
        desktop.settings = defaults();
        desktop.entries = [entry("codex", 60), entry("claude", 35)];
        desktop.busy = false; desktop.stale = false; desktop.error = ""; desktop.configError = "";
        desktop.refreshCount = 0; desktop.geometryWrites = 0; desktop.menuRequests = 0;
        gauge = createTemporaryObject(gaugeComponent, testCase);
        verify(gauge);
        tryCompare(gauge, "visible", true);
        verify(waitForRendering(gauge.contentItem));
    }
    function test_defaultCapsuleDoesNotRequestUsage() {
        compare(gauge.compact, true);
        compare(gauge.height, 48);
        verify(shown("60% left"));
        verify(shown("35% left"));
        verify(!findChild(gauge, "capsuleStatus").visible);
        compare(desktop.refreshCount, 0);
        verify(!shown("private@example.invalid"));
    }
    function test_windowsFollowReportedUsage() {
        var weekly = entry("codex", 42);
        weekly.plan = "pro";
        weekly.windows[0].label = "Weekly";
        weekly.windows[0].resetsAt = new Date(gauge.now + 4 * 86400000).toISOString();
        desktop.entries = [weekly];
        tryVerify(function() { return shown("Weekly") && shown("42% left"); });
        verify(!shown("5h"));
        verify(shown("Resets in 4d 0h"));
        var weeklyWidth = gauge.width;
        verify(waitForRendering(gauge.contentItem));
        grabImage(gauge.contentItem).save("/tmp/floating-weekly.png");
        var dual = entry("codex", 3);
        dual.windows[0].label = "5h";
        dual.windows.push({label: "Weekly", remaining: 71, resetsAt: "2030-01-01T00:00:00Z"});
        desktop.entries = [dual];
        tryVerify(function() { return shown("3% left") && shown("71% left"); });
        verify(shown("5h"));
        verify(shown("Weekly"));
        tryVerify(function() { return gauge.width > weeklyWidth; });
        verify(!findChild(gauge, "capsuleStatus").visible);
        verify(waitForRendering(gauge.contentItem));
        grabImage(gauge.contentItem).save("/tmp/floating-dual-window.png");
        desktop.busy = true;
        tryVerify(function() { return shown("↻"); });
        desktop.busy = false;
        desktop.stale = true;
        tryVerify(function() { return shown("!"); });
        desktop.stale = false;
        desktop.saveSettings({quotaDisplay: "used"});
        tryVerify(function() { return shown("97% used") && shown("29% used"); });
    }
    function test_capsuleHoverDoesNotCoverUsage() {
        var drag = findChild(gauge, "capsuleDrag");
        mouseMove(drag, drag.width / 2, drag.height / 2);
        tryCompare(drag, "containsMouse", true);
        compare(drag.ToolTip.visible, false);
        verify(drag.Accessible.description.indexOf("Updated 12:00") !== -1);
        verify(drag.Accessible.description.indexOf("Click to expand") !== -1);
        compare(gauge.height, 48);
        verify(shown("60% left"));
        verify(shown("35% left"));
        compare(desktop.refreshCount, 0);
        grabImage(gauge.contentItem).save("floating-capsule-hover-synthetic.png");
        gauge.setCompact(false);
        tryVerify(function() { return shown("Updated 12:00"); });
    }
    function test_clickExpandsAndCollapseRestoresCapsule() {
        var drag = findChild(gauge, "capsuleDrag");
        verify(drag);
        mousePress(drag, drag.width / 2, drag.height / 2);
        compare(drag.pressed, true);
        mouseRelease(drag, drag.width / 2, drag.height / 2);
        tryCompare(gauge, "compact", false);
        compare(gauge.width, 360);
        compare(gauge.height, 440);
        tryVerify(function() { return shown("60% left"); });
        var collapse = findChild(gauge, "collapseButton");
        verify(waitForRendering(gauge.contentItem));
        mouseClick(collapse, collapse.width / 2, collapse.height / 2);
        tryCompare(gauge, "compact", true);
        compare(gauge.height, 48);
        compare(desktop.refreshCount, 0);
    }
    function test_dragDoesNotExpand() {
        var drag = findChild(gauge, "capsuleDrag");
        mouseDrag(drag, 20, 20, Qt.styleHints.startDragDistance + 20, 0, Qt.LeftButton);
        compare(drag.moved, true);
        compare(gauge.compact, true);
        compare(desktop.refreshCount, 0);
    }
    function test_rightClickUsesIndependentMenuWithoutExpanding() {
        var drag = findChild(gauge, "capsuleDrag");
        mouseClick(drag, drag.width / 2, drag.height / 2, Qt.RightButton);
        compare(desktop.menuRequests, 1);
        compare(gauge.compact, true);
        desktop.floatingActionRequested("toggle");
        compare(gauge.compact, false);
        desktop.floatingActionRequested("hide");
        compare(gauge.visible, false);
        compare(desktop.refreshCount, 0);
    }
    function test_expandedSizeSurvivesRoundTrip() {
        gauge.setCompact(false);
        gauge.width = 510; gauge.height = 570;
        gauge.setCompact(true);
        compare(desktop.settings.floatingWidth, 510);
        compare(desktop.settings.floatingHeight, 570);
        gauge.setCompact(false);
        compare(gauge.width, 510);
        compare(gauge.height, 570);
    }
    function test_displayFilterDoesNotChangeFetchedProviders() {
        desktop.saveSettings({floatingProviders: ["claude"]});
        tryCompare(gauge, "shownEntries", [desktop.entries[1]]);
        verify(!shown("60% left"));
        verify(shown("35% left"));
        compare(desktop.entries.length, 2);
        compare(desktop.refreshCount, 0);
    }
    function test_usedModeIsExplicit() {
        desktop.saveSettings({quotaDisplay: "used"});
        tryVerify(function() { return shown("40% used"); });
        verify(!shown("left ▾"));
        gauge.setCompact(false);
        tryVerify(function() { return shown("40% used"); });
    }
    function test_emptyAndUnknownQuotaDoNotShowZero() {
        desktop.entries = [];
        tryVerify(function() { return shown("CodexBar · No usage"); });
        var unknown = entry("codex", 60);
        unknown.windows = [];
        desktop.entries = [unknown];
        tryVerify(function() { return shown("—"); });
        verify(!shown("0%"));
    }
    function test_extraProvidersRemainAvailableInExpandedMode() {
        desktop.entries = [entry("codex", 60), entry("claude", 35), entry("copilot", 80), entry("gemini", 90)];
        tryVerify(function() { return shown("+1"); });
        gauge.setCompact(false);
        compare(gauge.shownEntries.length, 4);
    }
    function test_multiAccountIsIndependentAndIdentityIsOptIn() {
        desktop.entries = [entry("codex", 60, 1), entry("codex", 10, 2)];
        gauge.setCompact(false);
        tryVerify(function() { return shown("Account 1") && shown("Account 2"); });
        verify(shown("60% left"));
        verify(shown("10% left"));
        verify(!shown("private@example.invalid"));
        desktop.saveSettings({showIdentity: true});
        tryVerify(function() { return shown("private@example.invalid"); });
    }
    function test_failedEntryAndStaleCacheStayVisible() {
        var failed = entry("claude", 35);
        failed.failed = true; failed.error = "Synthetic provider failure";
        desktop.entries = [entry("codex", 60), failed];
        desktop.stale = true; desktop.error = "Retained usage may be out of date";
        tryVerify(function() { return shown("!"); });
        verify(shown("60% left"));
        gauge.setCompact(false);
        tryVerify(function() { return shown("Retained usage may be out of date"); });
        verify(shown("Synthetic provider failure"));
        verify(shown("35% left"));
    }
    function test_visibilityAndTopmostFollowSettings() {
        verify((gauge.flags & Qt.WindowStaysOnTopHint) !== 0);
        verify((gauge.flags & Qt.WindowDoesNotAcceptFocus) !== 0);
        desktop.saveSettings({floatingOnTop: false});
        tryVerify(function() { return (gauge.flags & Qt.WindowStaysOnTopHint) === 0; });
        compare(gauge.visible, true);
        gauge.hideGauge();
        tryCompare(gauge, "visible", false);
        compare(desktop.settings.showFloating, false);
        desktop.saveSettings({showFloating: true});
        tryCompare(gauge, "visible", true);
        compare(desktop.refreshCount, 0);
    }
    function test_dualWindowEntriesFitAvailableScreen() {
        var entries = [entry("codex", 60), entry("claude", 35), entry("copilot", 80)];
        entries.forEach(function(value) { value.windows.push({label: "Weekly", remaining: 71, resetsAt: ""}); });
        desktop.entries = entries;
        gauge.compactAvailableWidth = 1024;
        tryCompare(gauge, "compactEntries", entries.slice(0, 2));
        verify(gauge.width <= 1024);
        verify(shown("+1"));
        verify(!shown("80% left"));
        gauge.setCompact(false);
        tryVerify(function() { return shown("80% left"); });
        compare(desktop.refreshCount, 0);
    }
    function test_screenChangesUpdateOverflow() {
        var entries = [entry("codex", 60), entry("claude", 35), entry("copilot", 80), entry("gemini", 90)];
        entries.forEach(function(value) { value.windows.push({label: "Weekly", remaining: 71, resetsAt: ""}); });
        desktop.entries = entries;
        for (var item of [{width: 1280, visible: 3}, {width: 1024, visible: 2},
                         {width: 640, visible: 1}, {width: 240, visible: 0}, {width: 1280, visible: 3}]) {
            gauge.compactAvailableWidth = item.width;
            tryVerify(function() { return gauge.compactEntries.length === item.visible; });
            verify(gauge.width <= item.width);
            verify(shown("+" + (entries.length - item.visible)));
        }
        compare(desktop.entries.length, 4);
        compare(desktop.refreshCount, 0);
    }
    function test_statusHasSpaceAtWidthBoundary() {
        var entries = [entry("codex", 60), entry("claude", 35)];
        entries.forEach(function(value) { value.windows.push({label: "Weekly", remaining: 71, resetsAt: ""}); });
        desktop.entries = entries;
        gauge.compactAvailableWidth = 758;
        tryVerify(function() { return gauge.compactEntries.length === 2; });
        desktop.busy = true;
        tryVerify(function() { return gauge.compactEntries.length === 1; });
        verify(shown("+1"));
        verify(shown("↻"));
        verify(gauge.width <= 758);
        desktop.busy = false;
        tryVerify(function() { return gauge.compactEntries.length === 2; });
    }
}
