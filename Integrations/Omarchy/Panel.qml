import QtQuick
import QtQuick.Effects
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
    // Clear the body first: a reader that exits without emitting would otherwise leave the
    // previous cycle's text to be parsed again and reported as a fresh, healthy snapshot.
    function poll() { if (!reader.running) { response = ""; reader.running = true; } }
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
        // One segment per displayed provider; older backends publish no barEntries and get the plain label.
        // Bindings here must tolerate snapshot === {} and mid-reload states: a binding that
        // throws is discarded by the engine and never re-evaluated.
        readonly property var segments: root.available && root.snapshot && Array.isArray(root.snapshot.barEntries)
            ? root.snapshot.barEntries : []
        readonly property bool icons: Array.isArray(segments) && segments.length > 0
        // The backend formats the lanes and the weekly pace; the bar only prefixes stale data.
        text: !root.available ? "CodexBar —" : (root.snapshot.stale ? "! " : "") +
            (root.snapshot.barLabel || root.snapshot.summary || "CodexBar —")
        // The own label stays the tooltip fallback and the fallback renderer; icons replace it when present.
        labelVisible: !icons
        fixedWidth: icons ? badges.implicitWidth + scaledHorizontalMargin * 2 : -1
        tooltipText: "CodexBar · quota " + (root.snapshot.quotaDisplay || "remaining") + "\nClick for usage · middle-click to refresh"
        onPressed: function(code) { if (code === Qt.MiddleButton) root.refresh(); else root.toggle(); }
        Row {
            id: badges
            anchors.centerIn: parent
            visible: button.icons
            spacing: Style.space(4)
            Text {
                visible: root.snapshot.stale === true
                text: "!"
                color: button.foreground
                font.family: button.fontFamily; font.pixelSize: button.fontSize
                anchors.verticalCenter: parent.verticalCenter
            }
            Repeater {
                model: button.segments
                Row {
                    id: segment
                    required property var modelData
                    required property int index
                    spacing: Style.space(4)
                    Text {
                        visible: segment.index > 0
                        text: "·"
                        color: button.foreground; opacity: 0.55
                        font.family: button.fontFamily; font.pixelSize: button.fontSize
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Item {
                        id: badge
                        // A provider without an installed logo keeps its text tag instead of a gap.
                        readonly property url icon: modelData && modelData.provider
                            ? Qt.resolvedUrl("icons/ProviderIcon-" + modelData.provider + ".svg") : ""
                        readonly property bool loaded: badgeIcon.status === Image.Ready
                        // Size to whichever child is drawn. Taking the larger of the two
                        // reserved the hidden tag's width, which is the full provider id for
                        // anything without a short tag, leaving a gap beside the logo.
                        implicitWidth: badge.loaded ? badgeIcon.width : badgeTag.implicitWidth
                        implicitHeight: badge.loaded ? badgeIcon.height : badgeTag.implicitHeight
                        width: implicitWidth; height: implicitHeight
                        anchors.verticalCenter: parent.verticalCenter
                        Image {
                            id: badgeIcon
                            anchors.verticalCenter: parent.verticalCenter
                            source: badge.icon
                            // Without sourceSize the 100x100 SVGs rasterise at natural size and look soft.
                            // A logo needs more than cap height to read at bar size, so it runs a
                            // quarter larger than the text it labels and stays centred on it.
                            readonly property int extent: Math.round(button.fontSize * 1.5)
                            sourceSize: Qt.size(extent, extent)
                            visible: false
                        }
                        MultiEffect {
                            anchors.fill: badgeIcon
                            source: badgeIcon
                            visible: badge.loaded
                            // Colorization scales each pixel's luminance, so a logo drawn in black
                            // would stay black. Flatten every pixel to white first, keeping only the
                            // alpha, so each mark becomes an exact tint of the bar's foreground.
                            contrast: -1.0
                            brightness: 0.5
                            colorization: 1.0
                            colorizationColor: button.foreground
                        }
                        Text {
                            id: badgeTag
                            visible: !badge.loaded
                            text: modelData && modelData.tag ? modelData.tag : ""
                            color: button.foreground
                            font.family: button.fontFamily; font.pixelSize: button.fontSize
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                    Text {
                        text: modelData && modelData.text ? modelData.text : ""
                        color: button.foreground
                        font.family: button.fontFamily; font.pixelSize: button.fontSize
                        textFormat: Text.PlainText
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
            Text {
                // The joined label that carries this count is hidden while marks are drawn, so
                // the providers beyond the bar's display limit are counted here instead.
                readonly property int extra: {
                    var total = root.available && root.snapshot && Array.isArray(root.snapshot.entries)
                        ? root.snapshot.entries.length : 0
                    var shown = Array.isArray(button.segments) ? button.segments.length : 0
                    return total - shown
                }
                visible: extra > 0
                text: "+" + extra
                color: button.foreground
                font.family: button.fontFamily; font.pixelSize: button.fontSize
                anchors.verticalCenter: parent.verticalCenter
            }
        }
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
