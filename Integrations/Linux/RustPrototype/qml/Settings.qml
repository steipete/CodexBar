import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ApplicationWindow {
    id: window
    title: "CodexBar prototype — Settings"
    width: 520; height: 510
    minimumWidth: 420; minimumHeight: 450
    property string feedback: ""
    onClosing: function(event) { event.accepted = false; hide(); }
    Shortcut { sequence: "Escape"; onActivated: window.hide() }
    Shortcut { sequence: "Ctrl+S"; onActivated: window.save() }
    function save() {
        if (desktop.saveSettings({quotaDisplay: quota.currentText, resetDisplay: reset.currentText,
            trayStyle: style.currentText, warningColors: warnings.checked, notifyThreshold: threshold.value,
            refreshOnOpen: refreshOnOpen.checked})) window.feedback = "Settings saved";
    }
    function load() {
        quota.currentIndex = quota.model.indexOf(desktop.settings.quotaDisplay);
        reset.currentIndex = reset.model.indexOf(desktop.settings.resetDisplay);
        style.currentIndex = style.model.indexOf(desktop.settings.trayStyle);
        warnings.checked = desktop.settings.warningColors;
        threshold.value = desktop.settings.notifyThreshold;
        refreshOnOpen.checked = desktop.settings.refreshOnOpen;
        feedback = "";
    }
    onVisibleChanged: if (visible) { load(); console.info("Rust settings opened"); capture.restart(); }
    Timer { id: capture; interval: 200; onTriggered: desktop.captureWindow(window, "settings") }
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 24; spacing: 16
        Label { text: "Settings"; font.pixelSize: 24; font.bold: true }
        Label { text: "Display preferences for the Rust prototype. Usage is synthetic."; opacity: 0.65; wrapMode: Text.Wrap; Layout.fillWidth: true }
        GridLayout {
            columns: 2; columnSpacing: 20; rowSpacing: 12; Layout.fillWidth: true
            Label { text: "Quota"; Layout.fillWidth: true }
            ComboBox { id: quota; model: ["remaining", "used"]; Accessible.name: "Quota display" }
            Label { text: "Reset time" }
            ComboBox { id: reset; model: ["countdown", "absolute", "both"]; Accessible.name: "Reset time format" }
            Label { text: "Tray style" }
            ComboBox { id: style; model: ["meters", "icon"]; Accessible.name: "Tray style" }
            Label { text: "Low quota threshold" }
            SpinBox { id: threshold; from: 1; to: 99; editable: true; Accessible.name: "Remaining quota warning threshold" }
        }
        CheckBox { id: warnings; text: "Highlight low quota" }
        CheckBox { id: refreshOnOpen; text: "Refresh when clicking the tray" }
        Label { text: desktop.configError || window.feedback; visible: text !== ""; wrapMode: Text.Wrap; Layout.fillWidth: true }
        Item { Layout.fillHeight: true }
        RowLayout {
            Layout.fillWidth: true
            Button { text: "Close"; onClicked: window.hide() }
            Item { Layout.fillWidth: true }
            Button {
                text: "Save"; highlighted: true
                onClicked: window.save()
            }
        }
    }
}
