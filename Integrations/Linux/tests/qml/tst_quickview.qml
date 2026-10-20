import QtQuick
import QtTest
import "../../qml" as Desktop

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
}
