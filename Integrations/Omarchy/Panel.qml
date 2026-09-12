import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Usage.js" as Usage

Panel {
    id: root
    moduleName: "steipete.codexbar"
    ipcTarget: moduleName
    manageIpc: false
    property var entries: []
    property string failure: ""
    property double now: Date.now()
    property double lastRefresh: 0
    property string output: ""
    property int lastExitCode: -1
    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property bool stale: lastRefresh > 0 && (failure !== "" || now - lastRefresh > 600000)
    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function refresh() {
        if (probe.running) return;
        output = "";
        probe.running = true;
    }
    Component.onCompleted: Qt.callLater(refresh)
    onSettingsChanged: Qt.callLater(refresh)
    IpcHandler {
        target: root.ipcTarget
        function open(): void { root.open(); }
        function close(): void { root.close(); }
        function refresh(): void { root.refresh(); }
        function status(): string {
            return JSON.stringify({running: probe.running, exitCode: root.lastExitCode,
                outputBytes: root.output.length, providers: root.entries.length,
                summary: Usage.summary(root.entries), failure: root.failure});
        }
    }
    Timer {
        interval: Math.max(60, Number(root.setting("refreshSeconds", 300)) || 300) * 1000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }
    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.now = Date.now()
    }
    Process {
        id: probe
        command: ["timeout", "60", String(root.setting("executable", "codexbar")), "usage",
            "--provider", String(root.setting("provider", "codex")), "--format", "json", "--json-only"]
        stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.output = text }
        // Provider diagnostics may contain personal data; never forward them to shell logs.
        stderr: StdioCollector {}
        onExited: function(code, status) {
            root.lastExitCode = code;
            try {
                var parsed = Usage.rows(root.output);
                root.entries = parsed;
                root.failure = "";
                root.lastRefresh = Date.now();
            } catch (error) {
                root.failure = code === 124 ? "Refresh timed out. Press R to retry." :
                    "Unable to fetch usage. Check the CLI path and provider login; press R to retry.";
            }
            root.now = Date.now();
        }
    }
    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: (root.stale ? "! " : "") + (root.entries.length ? Usage.summary(root.entries) : "CX —")
        tooltipText: "CodexBar · quota remaining\nClick for details · middle-click to refresh"
        onPressed: function(code) {
            if (code === Qt.MiddleButton || code === Qt.RightButton) root.refresh();
            else root.toggle();
        }
    }
    KeyboardPanel {
        id: popup
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keys
        contentWidth: fittedContentWidth(Style.space(360))
        contentHeight: fittedContentHeight(content.implicitHeight, Style.space(560))
        PanelKeyCatcher {
            id: keys
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.switchPanel(direction); }
            onTextKey: function(text) { if (text.toLowerCase() === "r") root.refresh(); }
            Flickable {
                anchors.fill: parent
                contentWidth: width
                contentHeight: content.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}
                Column {
                    id: content
                    width: parent.width
                    spacing: Style.space(14)
                    Text {
                        text: "CodexBar"
                        color: root.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.heading
                        font.bold: true
                    }
                    DetailText {
                        text: probe.running ? "Refreshing…" : root.failure || (root.lastRefresh ?
                            "Quota remaining · updated " + Qt.formatTime(new Date(root.lastRefresh), "HH:mm") : "Waiting for usage…")
                    }
                    Repeater {
                        model: root.entries
                        Column {
                            required property var modelData
                            width: content.width
                            spacing: Style.space(8)
                            DetailText {
                                text: modelData.provider.toUpperCase() + (modelData.source ? " · " + modelData.source : "")
                                font.bold: true
                            }
                            DetailText { text: modelData.error; visible: text !== "" }
                            Repeater {
                                model: modelData.windows
                                Column {
                                    required property var modelData
                                    width: content.width
                                    spacing: Style.space(4)
                                    DetailText { text: modelData.label + " · " + modelData.remaining + "% left" }
                                    Rectangle {
                                        width: parent.width
                                        height: Style.space(6)
                                        radius: height / 2
                                        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)
                                        Rectangle {
                                            width: parent.width * modelData.remaining / 100
                                            height: parent.height
                                            radius: height / 2
                                            color: modelData.remaining <= 10 ? Color.urgent : Color.accent
                                        }
                                    }
                                    DetailText {
                                        text: Usage.resetLabel(modelData.resetsAt, root.now)
                                        opacity: 0.65
                                    }
                                }
                            }
                            DetailText {
                                visible: modelData.credits !== null
                                text: "Credits: " + modelData.credits
                            }
                        }
                    }
                    DetailText { visible: root.stale; text: "Showing older data"; color: Color.urgent }
                    Button {
                        text: probe.running ? "Refreshing…" : "Refresh  ·  R"
                        enabled: !probe.running
                        onClicked: root.refresh()
                    }
                }
            }
        }
    }
    component DetailText: Text {
        width: parent.width
        color: root.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        textFormat: Text.PlainText
        wrapMode: Text.Wrap
    }
}
