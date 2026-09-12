import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import com.steipete.codexbar.prototype

Item {
    id: root
    Component.onCompleted: console.info("Rust prototype QML loaded")
    RustDesktop { id: backend }
    SystemPalette { id: systemPalette }
    Palette {
        id: windowPalette
        window: desktop.theme.background || systemPalette.window
        base: desktop.theme.background || systemPalette.base
        button: desktop.theme.background || systemPalette.button
        windowText: desktop.theme.foreground || systemPalette.windowText
        text: desktop.theme.foreground || systemPalette.text
        buttonText: desktop.theme.foreground || systemPalette.buttonText
        highlight: desktop.theme.accent || systemPalette.highlight
        highlightedText: desktop.theme.background || systemPalette.highlightedText
        alternateBase: desktop.theme.lighter_background || systemPalette.alternateBase
        disabled.windowText: desktop.theme.dark_foreground || systemPalette.mid
        disabled.text: desktop.theme.dark_foreground || systemPalette.mid
        disabled.buttonText: desktop.theme.dark_foreground || systemPalette.mid
    }
    Timer { interval: 10000; running: true; repeat: true; onTriggered: backend.reload_theme() }
    function styleWindow(window) {
        var originalFont = window.font.family;
        window.palette = Qt.binding(function() { return windowPalette; });
        window.font.family = Qt.binding(function() { return desktop.theme.background ? "monospace" : originalFont; });
    }
    // Compatibility facade for the shared Dashboard and UsageCard.
    QtObject {
        id: desktop
        readonly property var data: JSON.parse(backend.snapshotJson)
        readonly property var entries: data.entries
        readonly property var spending: data.spending
        readonly property var settings: data.settings
        readonly property var theme: settings.followOmarchyTheme ? JSON.parse(backend.themeJson) : ({})
        readonly property bool busy: false
        readonly property bool costBusy: false
        readonly property bool stale: data.stale
        readonly property string updated: data.updated
        readonly property string error: "Prototype — synthetic data only. Refresh changes the meters."
        readonly property string costError: "Spending is outside this prototype."
        readonly property string configError: data.configError || ""
        function refresh() { backend.dispatch("refresh"); }
        function refreshCosts() { backend.dispatch("refresh"); }
        function showWindow(page) { backend.dispatch(page); }
        function copySummary() { notice.open(); }
        function saveSettings(changes) { return backend.save_settings(JSON.stringify(changes)); }
        function captureWindow(window, name) {
            if (!backend.capturePath) return;
            console.info("Captured " + name + " palette: " + window.palette.window);
            window.contentItem.children[0].grabToImage(function(result) {
                if (!result.saveToFile(backend.capturePath + "." + name + ".png")) console.error("Capture failed");
            });
        }
    }
    Loader {
        id: dashboard
        source: "../../qml/Dashboard.qml"
        onStatusChanged: if (status === Loader.Error) Qt.exit(1)
        onLoaded: {
            console.info("Production dashboard loaded"); item.title = "CodexBar Rust prototype — DEMO";
            root.styleWindow(item);
            if (desktop.data.window !== "background") item.show();
        }
    }
    Loader { id: trayPanel; source: "TrayPanel.qml"; onLoaded: root.styleWindow(item); onStatusChanged: if (status === Loader.Error) Qt.exit(1) }
    Loader { id: settingsWindow; source: "Settings.qml"; onLoaded: root.styleWindow(item); onStatusChanged: if (status === Loader.Error) Qt.exit(1) }
    Dialog {
        id: notice
        parent: dashboard.item ? dashboard.item.contentItem : root
        title: "Rust integration prototype"
        modal: true
        standardButtons: Dialog.Ok
        Label { text: "Clipboard support has not been ported yet." }
    }
    function planGeometry(item) {
        if (typeof item.text === "string" && item.text === desktop.entries[0].plan)
            return {width: item.width, height: item.height, object: String(item),
                implicitWidth: item.implicitWidth, minimumWidth: item.Layout.minimumWidth,
                preferredWidth: item.Layout.preferredWidth, maximumWidth: item.Layout.maximumWidth,
                parentWidth: item.parent.width, columnWidth: item.parent.parent.width,
                contentWidth: item.parent.parent.parent.width};
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
        onTriggered: if (dashboard.item && dashboard.item.visible && backend.capturePath) {
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
                var page = desktop.data.window;
                if (page === "background") {
                    dashboard.item.hide();
                    if (settingsWindow.item) settingsWindow.item.hide();
                    if (trayPanel.item) trayPanel.item.hide();
                } else if (page === "tray" && trayPanel.item) {
                    trayPanel.item.present(desktop.data.trayX, desktop.data.trayY);
                } else if (page === "settings" && settingsWindow.item) {
                    if (trayPanel.item) trayPanel.item.hide();
                    settingsWindow.item.show(); settingsWindow.item.raise(); settingsWindow.item.requestActivate();
                } else {
                    dashboard.item.selectedTab = page === "spending" ? 1 : 0;
                    dashboard.item.show(); dashboard.item.raise(); dashboard.item.requestActivate();
                }
            }
        }
    }
}
