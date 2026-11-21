import QtQuick
import QtTest
import "../../qml" as Desktop
import "../../Shared/Usage.js" as Usage

TestCase {
    id: testCase
    name: "QuickView"
    when: windowShown
    QtObject {
        id: desktop
        property var settings: ({showCosts: true, quotaDisplay: "remaining", resetDisplay: "countdown",
            showPace: true, warningColors: true, notifyThreshold: 10})
        property var entries: [{provider: "codex", accountLabel: "", plan: "Synthetic plan",
            windows: [{label: "Session", remaining: 60, resetsAt: "2030-01-01T00:00:00Z", pace: ""}],
            credits: null, error: "", status: "", details: []}]
        property var spending: []
        property bool busy: false
        property bool stale: false
        property string updated: "just now"
        property string error: ""
        property bool costBusy: false
        property string costError: ""
        signal changed()
        function refresh() {}
        function fitQuickView(window, compact) {}
        function showWindow(page) {}
    }
    property var view: null
    Component { id: viewComponent; Desktop.QuickView {} }

    function textItem(item, text) {
        if (item.text === text && item.visible) return item;
        for (var i = 0; i < item.children.length; ++i) {
            var found = textItem(item.children[i], text);
            if (found) return found;
        }
        return null;
    }
    function shown(text) { return textItem(view.contentItem, text) !== null; }
    function init() {
        desktop.settings = {showCosts: true, quotaDisplay: "remaining", resetDisplay: "countdown",
            showPace: true, warningColors: true, notifyThreshold: 10};
        desktop.spending = [{provider: "codex", today: 3, month: 12, tokens: 100, provenance: "local",
            coverage: "History may be incomplete", error: "Synthetic provider cost error"}];
        desktop.costError = "Local spending could not be refreshed. Previous data may be stale.";
        desktop.costBusy = false;
        view = createTemporaryObject(viewComponent, testCase, {visible: true});
        verify(view);
    }
    function test_retainedCostShowsRefreshError() {
        tryVerify(function() { return shown(desktop.costError); });
        verify(shown("Today $3.00  ·  Last 30 days $12.00"));
    }
    function test_partialCostShowsCoverageAndProviderError() {
        tryVerify(function() { return shown("History may be incomplete"); });
        verify(shown("Synthetic provider cost error"));
    }
    function test_firstFailureIsVisibleWithoutCachedTotals() {
        desktop.spending = [];
        tryVerify(function() { return shown(desktop.costError); });
    }
    function test_refreshingRetainedCostIsVisible() {
        desktop.costError = "";
        desktop.costBusy = true;
        tryVerify(function() { return shown("Reading local history…"); });
    }
    function test_disabledCostsHideErrorsAndTotals() {
        desktop.settings = {showCosts: false, quotaDisplay: "remaining", resetDisplay: "countdown",
            showPace: true, warningColors: true, notifyThreshold: 10};
        tryVerify(function() { return !shown("Cost across accounts"); });
        verify(!shown(desktop.costError));
    }
    function test_syntheticRender() {
        tryVerify(function() { return shown("Cost across accounts"); });
        grabImage(view.contentItem).save("quick-view-synthetic.png");
    }
    function test_tabQuotaFillMatchesDisplayPreference() {
        var fill = findChild(view.contentItem, "tabQuotaFill-0");
        verify(fill);
        tryCompare(fill, "width", fill.parent.width * 0.6);

        desktop.settings = {showCosts: true, quotaDisplay: "used", resetDisplay: "countdown",
            showPace: true, warningColors: true, notifyThreshold: 10};
        tryCompare(fill, "width", fill.parent.width * 0.4);
    }
    function test_pinAndExpandPreservesSizeAndShowsLiveQuota() {
        view.width = 510;
        view.height = 550;
        const flags = view.flags;
        const pin = textItem(view.contentItem, "Pin compact");
        verify(pin);
        mouseClick(pin);
        tryCompare(view, "height", 40);
        verify(view.flags & Qt.WindowStaysOnTopHint);
        verify(shown("Session") && shown("60% left"));
        desktop.settings = Object.assign({}, desktop.settings, {quotaDisplay: "used"});
        tryVerify(function() { return shown("40% used"); });
        mouseClick(findChild(view.contentItem, "expandQuickView"));
        tryCompare(view, "height", 550);
        compare(view.width, 510);
        compare(view.flags, flags);
        verify(shown("Cost across accounts"));
    }
    function test_capsuleRefreshStatus() {
        desktop.settings = Object.assign({}, desktop.settings, {refreshSeconds: 300});
        view.setPinned(true);
        verify(shown("✓"));
        compare(view.refreshCadence, "Every 5 min");
        view.capsuleNow = Date.parse("2029-12-29T20:00:00Z");
        verify(shown("Resets in 2d 4h"));
        view.capsuleNow = Date.parse("2030-01-01T00:00:00Z");
        verify(shown("Reset due"));
        desktop.busy = true;
        verify(shown("↻"));
        desktop.busy = false;
        desktop.stale = true;
        verify(shown("◷"));
        desktop.error = "Synthetic refresh failure";
        verify(shown("!"));
        desktop.error = "";
        desktop.stale = false;
        desktop.settings = Object.assign({}, desktop.settings, {refreshSeconds: 90});
        compare(view.refreshCadence, "Every 90 s");
    }
    function test_capsuleProviderWithoutQuotaWindows() {
        const previousEntries = desktop.entries;
        try {
            desktop.entries = Usage.rows(JSON.stringify({provider: "vertexai", usage: {}}), false);
            view.setPinned(true);
            compare(view.capsuleStatus, "No usage");
            verify(shown("…"));

            desktop.entries = Usage.rows(JSON.stringify({provider: "vertexai", error: "Synthetic failure"}), false);
            compare(view.capsuleStatus, "Refresh failed");
            verify(shown("!"));
        } finally {
            desktop.entries = previousEntries;
        }
    }
}
