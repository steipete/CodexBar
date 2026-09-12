import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../../qml" as Shared

ApplicationWindow {
    id: window
    title: "CodexBar — Quick usage"
    flags: Qt.Tool | Qt.FramelessWindowHint
    width: 380
    height: content.implicitHeight + 32
    minimumWidth: 380; maximumWidth: 380
    minimumHeight: content.implicitHeight + 32; maximumHeight: content.implicitHeight + 32
    onVisibleChanged: if (visible) { console.info("Rust tray panel opened"); capture.restart(); }
    Timer { id: capture; interval: 200; onTriggered: desktop.captureWindow(window, "tray") }
    onClosing: function(event) { event.accepted = false; hide(); }
    Shortcut { sequence: "Escape"; onActivated: window.hide() }
    Shortcut { sequence: "Ctrl+,"; onActivated: window.openSettings() }
    Shortcut { sequence: "Ctrl+R"; onActivated: desktop.refresh() }
    function openSettings() { hide(); desktop.showWindow("settings"); }
    // Delay dismissal so a newly requested Wayland activation can arrive first.
    onActiveChanged: if (active) dismiss.stop(); else dismiss.restart()
    Timer { id: dismiss; interval: 250; onTriggered: if (!window.active) window.hide() }
    function present(xHint, yHint) {
        if (xHint > 0) {
            x = Math.max(screen.virtualX, Math.min(xHint - width / 2, screen.virtualX + screen.width - width));
            y = Math.max(screen.virtualY, Math.min(yHint + 12, screen.virtualY + screen.height - height));
        }
        show(); raise(); requestActivate();
    }
    ColumnLayout {
        id: content
        anchors.left: parent.left; anchors.right: parent.right
        anchors.top: parent.top; anchors.margins: 16
        spacing: 12
        RowLayout {
            Layout.fillWidth: true
            Label { text: "CodexBar"; font.pixelSize: 20; font.bold: true; Layout.fillWidth: true }
            Label { text: "DEMO"; opacity: 0.65; font.pixelSize: 11 }
            ToolButton { text: "×"; Accessible.name: "Close quick usage"; onClicked: window.hide() }
        }
        Repeater {
            model: desktop.entries
            Shared.UsageCard { required property var modelData; entry: modelData }
        }
        Label { text: desktop.updated; opacity: 0.65; Layout.fillWidth: true; wrapMode: Text.Wrap }
        RowLayout {
            Layout.fillWidth: true
            Button { text: "Refresh"; onClicked: desktop.refresh() }
            Item { Layout.fillWidth: true }
            Button { text: "Settings…"; onClicked: window.openSettings() }
        }
        Button { text: "Open Usage & Spend…"; Layout.fillWidth: true; onClicked: { window.hide(); desktop.showWindow("usage"); } }
    }
}
