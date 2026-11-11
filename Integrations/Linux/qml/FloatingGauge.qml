import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../Shared/Usage.js" as Usage

ApplicationWindow {
    id: window
    objectName: "floatingGauge"
    title: "CodexBar · Floating Gauge"
    visible: desktop.settings.showFloating
    color: "transparent"
    flags: Qt.Tool | Qt.FramelessWindowHint | Qt.WindowDoesNotAcceptFocus |
        (desktop.settings.floatingOnTop ? Qt.WindowStaysOnTopHint : 0)
    minimumWidth: compact ? capsuleWidth : 280
    maximumWidth: compact ? capsuleWidth : 1200
    minimumHeight: compact ? 48 : 220
    maximumHeight: compact ? 48 : 1200

    readonly property bool compact: desktop.settings.floatingCompact
    readonly property string suffix: desktop.settings.quotaDisplay === "used" ? "used" : "left"
    readonly property var shownEntries: {
        var selected = desktop.settings.floatingProviders || [];
        return desktop.entries.filter(function(entry) {
            return selected.length === 0 || selected.indexOf(entry.provider) !== -1;
        });
    }
    readonly property int capsuleWidth: Math.max(220, shownEntries.slice(0, 3).reduce(function(total, entry) {
        return total + 94 + Math.max(1, compactWindows(entry).length) * 132;
    }, 42))
    readonly property color secondaryText: Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.65)
    readonly property color warning: "#d97732"
    readonly property string stateText: desktop.busy ? "Refreshing…" : desktop.error ? desktop.error :
        desktop.stale ? "Data out of date" : desktop.updated ? "Updated " + desktop.updated : "Waiting for usage"
    property bool ready: false
    property bool applyingGeometry: false
    property double now: Date.now()

    function syncSize() {
        if (!ready) return;
        applyingGeometry = true;
        geometrySave.stop();
        width = compact ? capsuleWidth : desktop.settings.floatingWidth;
        height = compact ? 48 : desktop.settings.floatingHeight;
        applyingGeometry = false;
    }
    function restorePosition() {
        if (!ready || !visible) return;
        applyingGeometry = true;
        desktop.restoreFloatingGeometry(window);
        applyingGeometry = false;
    }
    function scheduleSave() {
        if (ready && visible && !applyingGeometry) geometrySave.restart();
    }
    function flushGeometry() {
        if (!ready || (!visible && !geometrySave.running)) return;
        geometrySave.stop();
        desktop.saveFloatingGeometry(window);
    }
    function setCompact(value) {
        flushGeometry();
        desktop.saveSettings({floatingCompact: value});
    }
    function hideGauge() {
        flushGeometry();
        desktop.saveSettings({showFloating: false});
    }
    function accountName(entry, index) {
        if (desktop.settings.showIdentity && entry.accountLabel) return entry.accountLabel;
        var matches = shownEntries.filter(function(other) { return other.provider === entry.provider; });
        return matches.length > 1 ? "Account " + (entry.accountNumber || index + 1) : "";
    }
    function compactWindows(entry) {
        return (entry.windows || []).filter(function(metric) { return !metric.scoped; }).slice(0, 2);
    }
    function quotaColor(metric) {
        return desktop.stale ? secondaryText : desktop.settings.warningColors && metric &&
            metric.remaining <= desktop.settings.notifyThreshold ? warning : palette.highlight;
    }

    onXChanged: scheduleSave()
    onYChanged: scheduleSave()
    onWidthChanged: scheduleSave()
    onHeightChanged: scheduleSave()
    onCompactChanged: { syncSize(); restorePosition(); }
    onCapsuleWidthChanged: if (compact) { syncSize(); restorePosition(); }
    // Crossing onto another monitor during a drag must not restore the old position.
    onVisibleChanged: {
        if (visible) { now = Date.now(); syncSize(); restorePosition(); }
        else if (geometrySave.running) flushGeometry();
    }
    onClosing: function(event) { event.accepted = false; hideGauge(); }
    Component.onCompleted: { ready = true; syncSize(); restorePosition(); }
    Connections {
        target: desktop
        function onSettingsChanged() { window.syncSize(); }
        function onFloatingActionRequested(action) {
            if (action === "toggle") window.setCompact(!window.compact);
            else if (action === "hide") window.hideGauge();
        }
    }
    Connections {
        target: Qt.application
        function onAboutToQuit() { window.flushGeometry(); }
        function onScreensChanged() { Qt.callLater(window.restorePosition); }
    }
    Connections {
        target: window.screen
        function onDesktopGeometryChanged() { Qt.callLater(window.restorePosition); }
    }
    Timer { id: geometrySave; interval: 400; onTriggered: desktop.saveFloatingGeometry(window) }
    Timer { interval: 30000; repeat: true; running: window.visible; onTriggered: window.now = Date.now() }

    background: Rectangle {
        color: window.palette.window
        radius: window.compact ? 24 : 14
        border.color: Qt.rgba(window.palette.windowText.r, window.palette.windowText.g, window.palette.windowText.b, 0.2)
    }

    // Right-click anywhere, including on a child control. Left presses are not intercepted.
    MouseArea {
        anchors.fill: parent
        z: 20
        acceptedButtons: Qt.RightButton
        onClicked: desktop.showFloatingMenu(window)
    }

    Item {
        id: capsule
        objectName: "capsule"
        anchors.fill: parent
        visible: window.compact
        Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left; anchors.leftMargin: 16
            spacing: 10
            Repeater {
                model: window.shownEntries.slice(0, 3)
                Row {
                    id: providerLane
                    required property var modelData
                    required property int index
                    width: 84 + Math.max(1, window.compactWindows(modelData).length) * 132
                    height: 40
                    spacing: 10
                    ProviderMark { provider: providerLane.modelData.provider; y: 13 }
                    Label {
                        text: Usage.providerName(providerLane.modelData.provider)
                        width: 50; y: 13
                        elide: Text.ElideRight
                        font.pixelSize: 11; font.bold: true
                        textFormat: Text.PlainText
                    }
                    Label {
                        visible: providerLane.modelData.failed || window.compactWindows(providerLane.modelData).length === 0
                        text: providerLane.modelData.failed ? "!" : "—"
                        color: providerLane.modelData.failed ? window.warning : window.secondaryText
                        y: 13
                    }
                    Repeater {
                        model: providerLane.modelData.failed ? [] : window.compactWindows(providerLane.modelData)
                        Column {
                            required property var modelData
                            width: 122; y: 3
                            spacing: 3
                            Row {
                                width: parent.width
                                spacing: 6
                                Label {
                                    text: modelData.label
                                    width: Math.max(0, parent.width - quotaText.width - 6)
                                    elide: Text.ElideRight
                                    font.pixelSize: 11
                                    color: window.secondaryText
                                    textFormat: Text.PlainText
                                }
                                Label {
                                    id: quotaText
                                    text: Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay) + "% " + window.suffix
                                    font.pixelSize: 11; font.bold: true
                                    color: desktop.settings.warningColors && modelData.remaining <= desktop.settings.notifyThreshold
                                        ? window.warning : window.palette.windowText
                                }
                            }
                            Rectangle {
                                width: parent.width; height: 3; radius: 1.5
                                color: Qt.rgba(window.palette.windowText.r, window.palette.windowText.g, window.palette.windowText.b, 0.12)
                                Rectangle {
                                    height: parent.height; radius: parent.radius
                                    width: parent.width * Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay) / 100
                                    color: window.quotaColor(modelData)
                                }
                            }
                            Label {
                                text: Usage.resetText(modelData.resetsAt, window.now, "countdown")
                                width: parent.width
                                elide: Text.ElideRight
                                font.pixelSize: 10
                                color: window.secondaryText
                            }
                        }
                    }
                }
            }
            Label { visible: window.shownEntries.length === 0; text: "CodexBar · No usage"; font.pixelSize: 12; y: 13 }
            Label {
                visible: window.shownEntries.length > 3
                text: "+" + (window.shownEntries.length - 3)
                color: window.secondaryText; font.pixelSize: 10
            }
            Label {
                y: 10
                objectName: "capsuleStatus"
                visible: desktop.error !== "" || desktop.stale || desktop.busy
                text: desktop.error || desktop.stale ? "!" : "↻"
                color: desktop.error || desktop.stale ? window.warning : window.palette.highlight
                font.pixelSize: 14; font.bold: true
                RotationAnimator on rotation {
                    from: 0; to: 360; duration: 1200; loops: Animation.Infinite
                    running: desktop.busy && !desktop.error && !desktop.stale && window.compact && window.visible
                }
            }
        }
        MoveArea {
            objectName: "capsuleDrag"
            anchors.fill: parent
            expandOnClick: true
            Accessible.role: Accessible.Button
            Accessible.name: "Expand floating gauge"
            Accessible.onPressAction: window.setCompact(false)
            // An in-window tooltip covers the 48px capsule. Show status in the
            // expanded panel and keep hover guidance available to screen readers.
            Accessible.description: window.stateText + "\nClick to expand · Drag to move · Right-click for options"
        }
    }

    Loader {
        anchors.fill: parent
        active: !window.compact
        sourceComponent: Component {
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 8
                visible: !window.compact
                RowLayout {
                    Layout.fillWidth: true
                    Item {
                        Layout.fillWidth: true; implicitHeight: 32
                        Label { anchors.verticalCenter: parent.verticalCenter; text: "CodexBar"; font.bold: true; font.pixelSize: 14 }
                        MoveArea { objectName: "panelDrag"; anchors.fill: parent }
                    }
                    ToolButton {
                        text: "↻"; enabled: !desktop.busy
                        Accessible.name: "Refresh usage"
                        onClicked: desktop.refresh()
                    }
                    ToolButton { objectName: "collapseButton"; text: "−"; Accessible.name: "Collapse gauge"; onClicked: window.setCompact(true) }
                    ToolButton { text: "⋯"; Accessible.name: "Gauge options"; onClicked: desktop.showFloatingMenu(window) }
                }
                Label {
                    text: window.stateText
                    color: desktop.error || desktop.stale ? window.warning : window.secondaryText
                    Layout.fillWidth: true; wrapMode: Text.Wrap; font.pixelSize: 11; textFormat: Text.PlainText
                }
                Label {
                    text: desktop.configError
                    visible: text !== ""
                    color: window.warning
                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                }
                ScrollView {
                    id: scroll
                    Layout.fillWidth: true; Layout.fillHeight: true
                    contentWidth: availableWidth; clip: true
                    ColumnLayout {
                        width: scroll.availableWidth
                        spacing: 10
                        Label {
                            visible: window.shownEntries.length === 0
                            text: "No usage to display. Check providers in Settings or refresh."
                            Layout.fillWidth: true; wrapMode: Text.Wrap; color: window.secondaryText
                        }
                        Repeater {
                            model: window.shownEntries
                            Frame {
                                id: card
                                required property var modelData
                                required property int index
                                Layout.fillWidth: true
                                padding: 10
                                background: Rectangle {
                                    radius: 8
                                    color: Qt.rgba(window.palette.windowText.r, window.palette.windowText.g, window.palette.windowText.b, 0.04)
                                }
                                ColumnLayout {
                                    width: parent.width
                                    spacing: 6
                                    RowLayout {
                                        Layout.fillWidth: true
                                        ProviderMark { provider: card.modelData.provider }
                                        Label { text: Usage.providerName(card.modelData.provider); font.bold: true; Layout.fillWidth: true; textFormat: Text.PlainText }
                                    }
                                    Label {
                                        text: window.accountName(card.modelData, card.index)
                                        visible: text !== ""; Layout.fillWidth: true; elide: Text.ElideRight
                                        font.pixelSize: 11; color: window.secondaryText; textFormat: Text.PlainText
                                    }
                                    Label {
                                        text: card.modelData.error || ""; visible: text !== ""
                                        Layout.fillWidth: true; wrapMode: Text.Wrap; color: window.warning; textFormat: Text.PlainText
                                    }
                                    Repeater {
                                        model: card.modelData.windows || []
                                        ColumnLayout {
                                            required property var modelData
                                            Layout.fillWidth: true; spacing: 4
                                            RowLayout {
                                                Layout.fillWidth: true
                                                Label { text: modelData.label; Layout.fillWidth: true; elide: Text.ElideRight; font.pixelSize: 12; textFormat: Text.PlainText }
                                                Label { text: Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay) + "% " + window.suffix; font.bold: true; font.pixelSize: 12 }
                                            }
                                            ProgressBar {
                                                Layout.fillWidth: true; from: 0; to: 100
                                                value: Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay)
                                                implicitHeight: 5
                                                background: Rectangle {
                                                    radius: 2.5
                                                    color: Qt.rgba(window.palette.windowText.r, window.palette.windowText.g, window.palette.windowText.b, 0.12)
                                                }
                                                contentItem: Item {
                                                    Rectangle {
                                                        width: parent.width * parent.parent.visualPosition
                                                        height: parent.height; radius: 2.5
                                                        color: window.quotaColor(modelData)
                                                    }
                                                }
                                            }
                                            Label {
                                                text: Usage.resetText(modelData.resetsAt, window.now, desktop.settings.resetDisplay)
                                                Layout.fillWidth: true; wrapMode: Text.Wrap; color: window.secondaryText; font.pixelSize: 11
                                            }
                                        }
                                    }
                                    Label {
                                        visible: card.modelData.credits !== null && card.modelData.credits !== undefined
                                        text: "Credits: " + card.modelData.credits
                                        Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                    }
                                }
                            }
                        }
                    }
                }
                Label { text: "Drag header to move · Right-click for options"; font.pixelSize: 10; color: window.secondaryText; Layout.fillWidth: true; elide: Text.ElideRight }
            }
        }
    }
    MouseArea {
        objectName: "resizeGrip"
        anchors.right: parent.right; anchors.bottom: parent.bottom
        width: 20; height: 20
        visible: !window.compact
        cursorShape: Qt.SizeFDiagCursor
        onPressed: function(mouse) {
            if (!window.startSystemResize(Qt.RightEdge | Qt.BottomEdge)) mouse.accepted = false;
        }
        Label { anchors.centerIn: parent; text: "◢"; color: window.secondaryText; font.pixelSize: 10 }
    }

    component ProviderMark: Item {
        required property string provider
        implicitWidth: 14; implicitHeight: 14
        Image {
            id: icon
            anchors.fill: parent
            source: "image://provider-icon/" + parent.provider + "?color=" + window.palette.windowText.toString().slice(1)
            sourceSize.width: 28; sourceSize.height: 28
            visible: status === Image.Ready
        }
        Label {
            anchors.centerIn: parent
            visible: icon.status !== Image.Ready
            text: parent.provider.slice(0, 1).toUpperCase()
            font.pixelSize: 10; font.bold: true
        }
    }

    component MoveArea: MouseArea {
        property bool expandOnClick: false
        property point pressPoint
        property bool moved: false
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor
        onPressed: function(mouse) { pressPoint = Qt.point(mouse.x, mouse.y); moved = false; }
        onPositionChanged: function(mouse) {
            if (pressed && !moved && Math.abs(mouse.x - pressPoint.x) + Math.abs(mouse.y - pressPoint.y) >= Qt.styleHints.startDragDistance) {
                moved = true;
                window.startSystemMove();
            }
        }
        onClicked: if (expandOnClick && !moved) window.setCompact(false)
    }
}
