import QtQuick
import QtQuick.Controls
import com.steipete.codexbar.prototype

Item {
    id: root
    Component.onCompleted: console.info("Rust prototype QML loaded")
    RustDesktop { id: backend }
    // Compatibility facade for the unchanged production Dashboard and UsageCard.
    QtObject {
        id: desktop
        readonly property var data: JSON.parse(backend.snapshotJson)
        readonly property var entries: data.entries
        readonly property var spending: data.spending
        readonly property var settings: data.settings
        readonly property bool busy: false
        readonly property bool costBusy: false
        readonly property bool stale: data.stale
        readonly property string updated: data.updated
        readonly property string error: "Prototype — synthetic data only. Refresh changes the meters."
        readonly property string costError: "Spending is outside this prototype."
        function refresh() { backend.dispatch("refresh"); }
        function refreshCosts() { backend.dispatch("refresh"); }
        function showWindow(page) { backend.dispatch(page); }
        function copySummary() { notice.open(); }
    }
    Loader {
        id: dashboard
        source: "../../qml/Dashboard.qml"
        onStatusChanged: if (status === Loader.Error) Qt.exit(1)
        onLoaded: { console.info("Production dashboard loaded"); item.title = "CodexBar Rust prototype — DEMO"; item.show(); }
    }
    Dialog {
        id: notice
        parent: dashboard.item ? dashboard.item.contentItem : root
        title: "Rust integration prototype"
        modal: true
        standardButtons: Dialog.Ok
        Label { text: "Settings, spending and clipboard are not implemented in this spike." }
    }
    function planGeometry(item) {
        if (typeof item.text === "string" && item.text === desktop.entries[0].plan)
            return {width: item.width, height: item.height};
        var children = item.children || [];
        for (var i = 0; i < children.length; ++i) {
            var geometry = planGeometry(children[i]);
            if (geometry) return geometry;
        }
        return null;
    }
    function meterLabels(item) {
        var labels = [];
        if (typeof item.text === "string" && item.text.endsWith("% left")) labels.push(item.text);
        var children = item.children || [];
        for (var i = 0; i < children.length; ++i) labels = labels.concat(meterLabels(children[i]));
        return labels;
    }
    Timer {
        id: captureTimer
        interval: 300
        onTriggered: if (dashboard.item && backend.capturePath) {
            console.info("Rendered meters: " + JSON.stringify(root.meterLabels(dashboard.item.contentItem)));
            console.info("Rendered plan: " + JSON.stringify(root.planGeometry(dashboard.item.contentItem)));
            dashboard.item.contentItem.children[0].grabToImage(function(result) {
                if (!result.saveToFile(backend.capturePath)) console.error("Capture failed");
            });
        }
    }
    Timer {
        interval: 100; running: true; repeat: true
        property int serial: -1
        property string lastUpdate: ""
        onTriggered: {
            backend.sync();
            if (lastUpdate !== desktop.updated) { lastUpdate = desktop.updated; captureTimer.restart(); }
            if (desktop.data.quit) Qt.quit();
            if (serial !== desktop.data.windowSerial && dashboard.item) {
                serial = desktop.data.windowSerial;
                dashboard.item.selectedTab = desktop.data.window === "spending" ? 1 : 0;
                dashboard.item.show(); dashboard.item.raise(); dashboard.item.requestActivate();
                if (desktop.data.window === "settings") notice.open();
            }
        }
    }
}
