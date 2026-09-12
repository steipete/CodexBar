import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Presentation only. The standalone app owns settings, polling and notifications.
Panel {
    id: root
    moduleName: "steipete.codexbar"
    ipcTarget: moduleName
    property var snapshot: ({})
    property string response: ""
    property bool available: false
    readonly property string executable: String(setting("desktopExecutable", "codexbar-linux"))
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight
    function poll() { if (!reader.running) reader.running = true; }
    function launch(page) { Quickshell.execDetached([executable, "--" + page]); close(); }
    function refresh() { Quickshell.execDetached([executable, "--refresh"]); }
    Component.onCompleted: Qt.callLater(poll)
    onSettingsChanged: Qt.callLater(poll)
    onOpenedChanged: if (opened) poll()
    Timer { interval: 5000; running: true; repeat: true; onTriggered: root.poll() }
    Process {
        id: reader
        command: [root.executable, "--snapshot"]
        stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.response = text }
        stderr: StdioCollector {}
        onExited: function(code) {
            try {
                var data = JSON.parse(root.response);
                if (code !== 0 || data.schemaVersion !== 1 || !Array.isArray(data.entries)) throw new Error("Unavailable");
                root.snapshot = data;
                root.available = true;
            } catch (error) { root.available = false; }
        }
    }
    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: !root.available ? "CodexBar —" : (root.snapshot.stale ? "! " : "") + (root.snapshot.summary || "CodexBar —")
        tooltipText: "CodexBar · quota " + (root.snapshot.quotaDisplay || "remaining") + "\nClick for usage · middle-click to refresh"
        onPressed: function(code) { if (code === Qt.MiddleButton) root.refresh(); else root.toggle(); }
    }
    KeyboardPanel {
        id: popup
        anchorItem: button; owner: root; bar: root.bar; open: root.opened
        focusTarget: keys
        contentWidth: fittedContentWidth(Style.space(330))
        contentHeight: fittedContentHeight(content.implicitHeight, Style.space(440))
        FocusScope {
            id: keys
            anchors.fill: parent
            Keys.onEscapePressed: root.close()
            Keys.onPressed: function(event) { if (event.key === Qt.Key_R) root.refresh(); }
            Flickable {
                anchors.fill: parent; clip: true
                contentHeight: content.implicitHeight; contentWidth: width
                Column {
                    id: content
                    width: parent.width; spacing: Style.space(12)
                    Caption { text: "CodexBar"; font.bold: true; font.pixelSize: Style.font.heading }
                    Caption {
                        text: !root.available ? "Open CodexBar to start background refresh." : root.snapshot.error ||
                            (root.snapshot.busy ? "Refreshing…" : "Updated " + root.snapshot.updated + (root.snapshot.stale ? " · older data" : ""))
                    }
                    Repeater {
                        model: root.available ? root.snapshot.entries : []
                        Column {
                            required property var modelData
                            width: content.width; spacing: Style.space(6)
                            Caption { text: modelData.provider.toUpperCase(); font.bold: true }
                            Caption { text: modelData.error; visible: text !== "" }
                            Repeater {
                                model: modelData.windows
                                Column {
                                    required property var modelData
                                    width: content.width; spacing: Style.space(4)
                                    Caption { text: modelData.label + " · " + (modelData.displayValue === undefined ? modelData.remaining : modelData.displayValue) + "% " + (modelData.displaySuffix || "left") }
                                    Rectangle {
                                        width: parent.width; height: Style.space(5); radius: height / 2
                                        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.15)
                                        Rectangle {
                                            width: parent.width * (modelData.displayValue === undefined ? modelData.remaining : modelData.displayValue) / 100; height: parent.height; radius: height / 2
                                            color: modelData.warning ? Color.urgent : Color.accent
                                        }
                                    }
                                    Caption {
                                        text: modelData.resetText || "Reset time unavailable"
                                        visible: text !== ""; opacity: 0.65
                                    }
                                }
                            }
                        }
                    }
                    Row {
                        spacing: Style.space(4)
                        Button { text: "Usage & Spend…"; focusable: true; onClicked: root.launch("usage") }
                        Button { text: "Settings…"; focusable: true; onClicked: root.launch("settings") }
                    }
                    Button { text: "Refresh"; focusable: true; enabled: root.available && !root.snapshot.busy; onClicked: root.refresh() }
                }
            }
        }
    }
    component Caption: Text {
        width: parent.width; color: Color.foreground; font.family: Style.font.family
        font.pixelSize: Style.font.body; textFormat: Text.PlainText; wrapMode: Text.Wrap
    }
}
