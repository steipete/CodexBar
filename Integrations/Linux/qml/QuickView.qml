import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../Shared/Usage.js" as Usage

ApplicationWindow {
    id: window
    title: "CodexBar"
    width: 420
    height: selectedIndex === -1 ? Math.min(650, 405 + desktop.entries.length * 54) : 680
    minimumWidth: pinned ? 180 : 360; minimumHeight: pinned ? 40 : 400
    property bool pinned: false
    property size expandedSize
    property int expandedFlags
    readonly property var capsuleEntry: selectedEntry || desktop.entries[0]
    readonly property bool capsuleRefreshFailed: !!desktop.error || !!(capsuleEntry && capsuleEntry.failed)
    readonly property string capsuleStatus: desktop.busy ? "Refreshing…" :
        capsuleRefreshFailed ? "Refresh failed" :
        desktop.stale ? "Stale" : !capsuleEntry || !capsuleEntry.windows.length ? "No usage" :
        desktop.updated ? "Up to date" : "Waiting…"
    readonly property string capsuleStatusIcon: desktop.busy ? "↻" :
        capsuleRefreshFailed ? "!" :
        desktop.stale ? "◷" : capsuleStatus === "Up to date" ? "✓" : "…"
    property double capsuleNow: Date.now()
    onPinnedChanged: if (pinned) capsuleNow = Date.now()
    readonly property string refreshCadence: {
        const seconds = desktop.settings.refreshSeconds;
        if (!seconds) return "";
        return seconds % 60 === 0 ? "Every " + seconds / 60 + " min" : "Every " + seconds + " s";
    }
    readonly property string capsuleSummary: {
        const entry = capsuleEntry;
        if (!entry) return desktop.busy ? "Loading usage…" : "Usage unavailable";
        const mode = desktop.settings.quotaDisplay;
        const quotas = entry.windows.slice(0, 2).map(metric =>
            metric.label + " " + Usage.quotaValue(metric.remaining, mode) + "%");
        const values = quotas.length ? quotas.join(" · ") + (mode === "used" ? " used" : " left") : "Usage unavailable";
        return Usage.providerName(entry.provider) + " · " + values + (desktop.stale ? " · Stale" : "");
    }

    function setPinned(value) {
        if (value === pinned) return;
        if (value) {
            expandedSize = Qt.size(width, height);
            expandedFlags = flags;
        }
        pinned = value;
        flags = value ? Qt.Window | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.NoDropShadowWindowHint : expandedFlags;
        width = value ? capsuleWidth : expandedSize.width;
        height = value ? 40 : expandedSize.height;
        Qt.callLater(fitWindow);
        if (!value) settleFrame.restart();
        if (!value) pinButton.forceActiveFocus();
        else expandButton.forceActiveFocus();
    }
    property int selectedIndex: 0 // -1 is Overview; entries may include multiple accounts.
    readonly property var selectedEntry: selectedIndex >= 0 && selectedIndex < desktop.entries.length ?
        desktop.entries[selectedIndex] : null
    readonly property var selectedCost: selectedEntry ? costFor(selectedEntry.provider) : null
    readonly property color primaryText: nativePalette.windowText
    readonly property color secondaryText: Qt.rgba(primaryText.r, primaryText.g, primaryText.b, 0.65)
    readonly property color accent: nativePalette.highlight
    readonly property color meterColor: "#c98757"
    readonly property color trackColor: Qt.rgba(primaryText.r, primaryText.g, primaryText.b, 0.14)
    readonly property color dividerColor: Qt.rgba(primaryText.r, primaryText.g, primaryText.b, 0.17)
    readonly property color hoverColor: Qt.rgba(primaryText.r, primaryText.g, primaryText.b, 0.08)

    function costFor(provider) {
        for (var i = 0; i < desktop.spending.length; ++i) {
            if (desktop.spending[i].provider === provider) return desktop.spending[i];
        }
        return null;
    }
    function openPage(page) { hide(); desktop.showWindow(page); }

    onClosing: function(event) { event.accepted = false; hide(); }
    Shortcut { sequence: "Ctrl+R"; onActivated: desktop.refresh() }
    Shortcut { sequence: "Ctrl+,"; onActivated: window.openPage("settings") }
    Shortcut { sequence: "Ctrl+Q"; onActivated: Qt.quit() }
    Shortcut { sequence: "Escape"; onActivated: window.hide() }
    Connections {
        target: desktop
        function onChanged() {
            if (window.pinned) window.capsuleNow = Date.now();
            if (desktop.entries.length && window.selectedIndex >= desktop.entries.length)
                window.selectedIndex = 0;
        }
    }
    SystemPalette { id: nativePalette }
    readonly property int capsuleWidth: Math.max(180, capsuleRow.implicitWidth + 45)
    function fitWindow() { desktop.fitQuickView(window, pinned); }
    // X11 window managers restore the title bar asynchronously after the flag change.
    Timer { id: settleFrame; interval: 120; onTriggered: if (!window.pinned) window.fitWindow() }
    onCapsuleWidthChanged: if (pinned) {
        width = capsuleWidth;
        Qt.callLater(fitWindow);
    }
    color: pinned ? "transparent" : nativePalette.window
    background: Rectangle {
        radius: window.pinned ? height / 2 : 0
        color: nativePalette.window
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 5
        anchors.rightMargin: 10
        visible: window.pinned
        spacing: 3
        Item {
            Layout.preferredWidth: 22
            Layout.fillHeight: true
            Grid {
                anchors.centerIn: parent
                columns: 2
                spacing: 2
                Repeater {
                    model: 6
                    Rectangle { width: 2; height: 2; radius: 1; color: window.secondaryText }
                }
            }
            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.SizeAllCursor
                hoverEnabled: true
                ToolTip.visible: containsMouse && !pressed
                ToolTip.delay: 700
                ToolTip.text: "Drag to move"
                onPressed: window.startSystemMove()
            }
        }
        ToolButton {
            id: expandButton
            objectName: "expandQuickView"
            Layout.fillWidth: true
            Layout.fillHeight: true
            padding: 0
            hoverEnabled: true
            readonly property string statusDescription: window.capsuleStatus + (window.refreshCadence ? " · " + window.refreshCadence : "") +
                (window.capsuleEntry ? window.capsuleEntry.windows.slice(0, 2).map(metric =>
                    "\n" + metric.label + " · " + Usage.resetText(metric.resetsAt, window.capsuleNow, "countdown")).join("") : "")
            Accessible.name: "Expand Quick View. " + window.capsuleSummary + ". " +
                statusDescription
            background: Rectangle {
                radius: height / 2
                color: expandButton.hovered || expandButton.down ? window.hoverColor : "transparent"
                border.width: expandButton.visualFocus ? 1 : 0
                border.color: window.accent
            }
            contentItem: RowLayout {
                id: capsuleRow
                spacing: 8
                Image {
                    source: window.capsuleEntry ? "image://provider-icon/" + window.capsuleEntry.provider +
                        "?color=" + window.primaryText.toString().slice(1) : ""
                    visible: status === Image.Ready
                    Layout.preferredWidth: 16
                    Layout.preferredHeight: 16
                    sourceSize: Qt.size(32, 32)
                }
                Label {
                    text: window.capsuleEntry ? Usage.providerName(window.capsuleEntry.provider) : "CodexBar"
                    textFormat: Text.PlainText
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                    color: window.primaryText
                }
                Repeater {
                    model: window.capsuleEntry ? window.capsuleEntry.windows.slice(0, 2) : []
                    Column {
                        required property var modelData
                        readonly property int percent: Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay)
                        Layout.preferredWidth: 108
                        spacing: 1
                        RowLayout {
                            width: parent.width
                            Label {
                                Layout.fillWidth: true
                                text: modelData.label
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                font.pixelSize: 11
                                color: window.secondaryText
                            }
                            Label {
                                text: percent + (desktop.settings.quotaDisplay === "used" ? "% used" : "% left")
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                                color: window.primaryText
                            }
                        }
                        Rectangle {
                            width: parent.width; height: 3; radius: 1.5
                            color: window.trackColor
                            Rectangle {
                                width: parent.width * percent / 100
                                height: parent.height; radius: parent.radius
                                color: window.meterColor
                            }
                        }
                        Label {
                            readonly property double resetAt: Date.parse(modelData.resetsAt)
                            visible: Number.isFinite(resetAt)
                            text: resetAt <= window.capsuleNow ? "Reset due" :
                                Usage.resetLabel(modelData.resetsAt, window.capsuleNow)
                            font.pixelSize: 10
                            color: window.secondaryText
                        }
                    }
                }
                Label {
                    text: window.capsuleStatusIcon
                    HoverHandler { id: statusHover }
                    ToolTip.visible: statusHover.hovered
                    ToolTip.delay: 700
                    ToolTip.text: expandButton.statusDescription
                    horizontalAlignment: Text.AlignHCenter
                    Layout.preferredWidth: 15
                    font.pixelSize: 14
                    color: window.primaryText
                }
            }
            onClicked: window.setPinned(false)
        }
    }
    ColumnLayout {
        visible: !window.pinned
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 20; Layout.rightMargin: 14
            Layout.topMargin: 12; Layout.bottomMargin: 8
            Label {
                text: "CodexBar"
                color: window.primaryText
                font.pixelSize: 14
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            ToolButton {
                id: pinButton
                text: "Pin compact"
                Accessible.name: "Collapse and pin Quick View"
                onClicked: window.setPinned(true)
            }
            ToolButton {
                text: "↻"
                enabled: !desktop.busy
                Accessible.name: "Refresh usage"
                onClicked: desktop.refresh()
                ToolTip.visible: hovered
                ToolTip.text: "Refresh usage"
                contentItem: Label {
                    text: "↻"
                    color: window.primaryText
                    font.pixelSize: 19
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    radius: 6
                    color: parent.hovered ? window.hoverColor : "transparent"
                }
            }
        }

        Flickable {
            id: switcher
            Layout.fillWidth: true
            Layout.preferredHeight: 69
            clip: true
            contentWidth: tabs.implicitWidth + 32
            contentHeight: height
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds
            Row {
                id: tabs
                x: 16
                spacing: 3
                height: parent.height - 6
                Item {
                    width: 72; height: parent.height
                    Rectangle {
                        anchors.fill: parent; anchors.bottomMargin: 4
                        radius: 9
                        color: window.selectedIndex === -1 ? window.accent : "transparent"
                    }
                    Label {
                        anchors.centerIn: parent
                        anchors.verticalCenterOffset: -7
                        text: "▦"
                        color: window.selectedIndex === -1 ? "white" : window.secondaryText
                        font.pixelSize: 17
                    }
                    Label {
                        anchors.bottom: parent.bottom; anchors.bottomMargin: 13
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "Overview"
                        color: window.selectedIndex === -1 ? "white" : window.secondaryText
                        font.pixelSize: 11
                    }
                    MouseArea {
                        anchors.fill: parent
                        activeFocusOnTab: true
                        Accessible.role: Accessible.Button
                        Accessible.name: "Overview"
                        onClicked: window.selectedIndex = -1
                        Keys.onReturnPressed: window.selectedIndex = -1
                        Keys.onSpacePressed: window.selectedIndex = -1
                    }
                }
                Repeater {
                    model: desktop.entries
                    Item {
                        required property var modelData
                        required property int index
                        width: 72; height: tabs.height
                        readonly property bool selected: window.selectedIndex === index
                        readonly property var firstWindow: modelData.windows.length ? modelData.windows[0] : null
                        Rectangle {
                            anchors.fill: parent; anchors.bottomMargin: 4
                            radius: 9
                            color: selected ? window.accent : "transparent"
                        }
                        Image {
                            id: providerIcon
                            source: "image://provider-icon/" + modelData.provider + "?color=" +
                                (selected ? "ffffff" : window.secondaryText.toString().slice(1))
                            width: 18; height: 18
                            sourceSize.width: 36; sourceSize.height: 36
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 5
                            visible: status === Image.Ready
                        }
                        Label {
                            visible: providerIcon.status !== Image.Ready
                            text: Usage.providerName(modelData.provider).slice(0, 2).toUpperCase()
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: 5
                            font.pixelSize: 12; font.bold: true
                            color: selected ? "white" : window.secondaryText
                        }
                        Label {
                            text: Usage.providerName(modelData.provider)
                            width: parent.width - 6
                            x: 3; y: 28
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                            font.pixelSize: 11
                            color: selected ? "white" : window.secondaryText
                            textFormat: Text.PlainText
                        }
                        Rectangle {
                            x: 10; width: parent.width - 20; height: 3
                            y: parent.height - 10; radius: 2
                            color: selected ? Qt.rgba(1, 1, 1, 0.4) : window.trackColor
                            Rectangle {
                                objectName: "tabQuotaFill-" + index
                                width: parent.width * (firstWindow ?
                                    Usage.quotaValue(firstWindow.remaining, desktop.settings.quotaDisplay) : 0) / 100
                                height: parent.height; radius: parent.radius
                                color: selected ? "white" : window.meterColor
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            activeFocusOnTab: true
                            Accessible.role: Accessible.Button
                            Accessible.name: Usage.providerName(modelData.provider) +
                                (modelData.accountLabel ? " " + modelData.accountLabel : "")
                            onClicked: window.selectedIndex = index
                            Keys.onReturnPressed: window.selectedIndex = index
                            Keys.onSpacePressed: window.selectedIndex = index
                        }
                    }
                }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: window.dividerColor }

        Flickable {
            id: bodyScroll
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.minimumHeight: 0
            clip: true
            contentWidth: width
            contentHeight: bodyContent.height
            boundsBehavior: Flickable.StopAtBounds
            Column {
                id: bodyContent
                width: bodyScroll.width
                spacing: 14
                Item { height: 2 }

                Label {
                    visible: desktop.entries.length === 0
                    text: desktop.busy ? "Loading usage…" : desktop.error || "No providers to show. Enable one in Settings."
                    x: 20; width: parent.width - 40
                    color: window.secondaryText
                    wrapMode: Text.Wrap
                }

                ColumnLayout {
                    visible: window.selectedIndex === -1 && desktop.entries.length > 0
                    x: 20; width: parent.width - 40
                    spacing: 12
                    Label {
                        text: "Overview"
                        color: window.primaryText
                        font.pixelSize: 20; font.weight: Font.DemiBold
                    }
                    Label {
                        text: desktop.busy ? "Refreshing usage…" : desktop.stale ?
                            "Usage may be out of date" : desktop.updated ? "Updated " + desktop.updated : "Waiting for usage…"
                        color: window.secondaryText; font.pixelSize: 12
                    }
                    Repeater {
                        model: desktop.entries
                        Rectangle {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            Layout.preferredHeight: 54
                            radius: 10
                            color: window.hoverColor
                            ColumnLayout {
                                id: overviewContent
                                anchors.fill: parent; anchors.margins: 11
                                spacing: 6
                                RowLayout {
                                    Layout.fillWidth: true
                                    Label {
                                        text: Usage.providerName(modelData.provider)
                                        color: window.primaryText
                                        font.pixelSize: 14; font.weight: Font.DemiBold
                                        Layout.fillWidth: true; elide: Text.ElideRight
                                    }
                                    Label {
                                        text: modelData.windows.length ?
                                            Usage.quotaValue(modelData.windows[0].remaining, desktop.settings.quotaDisplay) + "% " +
                                            (desktop.settings.quotaDisplay === "used" ? "used" : "left") : "—"
                                        color: window.secondaryText; font.pixelSize: 12
                                    }
                                }
                                Rectangle {
                                    Layout.fillWidth: true; height: 5; radius: 3; color: window.trackColor
                                    Rectangle {
                                        width: parent.width * (modelData.windows.length ?
                                            Usage.quotaValue(modelData.windows[0].remaining, desktop.settings.quotaDisplay) : 0) / 100
                                        height: parent.height; radius: parent.radius; color: window.meterColor
                                    }
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                activeFocusOnTab: true
                                Accessible.role: Accessible.Button
                                Accessible.name: "Show " + Usage.providerName(modelData.provider)
                                onClicked: window.selectedIndex = index
                                Keys.onReturnPressed: window.selectedIndex = index
                                Keys.onSpacePressed: window.selectedIndex = index
                            }
                        }
                    }
                }

                Column {
                    visible: window.selectedEntry !== null
                    x: 20; width: parent.width - 40
                    spacing: 14
                    RowLayout {
                        width: parent.width
                        Label {
                            text: window.selectedEntry ? Usage.providerName(window.selectedEntry.provider) : ""
                            color: window.primaryText
                            font.pixelSize: 21; font.weight: Font.DemiBold
                            Layout.fillWidth: true; elide: Text.ElideRight
                        }
                        Label {
                            text: window.selectedEntry ? window.selectedEntry.accountLabel : ""
                            visible: text !== ""
                            color: window.secondaryText
                            font.pixelSize: 12; elide: Text.ElideMiddle
                            Layout.maximumWidth: 150
                            textFormat: Text.PlainText
                        }
                    }
                    RowLayout {
                        width: parent.width
                        Label {
                            text: desktop.busy ? "Refreshing usage…" : desktop.stale ?
                                "Usage may be out of date" : desktop.updated ? "Updated " + desktop.updated : "Waiting for usage…"
                            color: window.secondaryText; font.pixelSize: 12
                            Layout.fillWidth: true; elide: Text.ElideRight
                        }
                        Label {
                            text: window.selectedEntry ? window.selectedEntry.plan : ""
                            visible: text !== ""
                            color: window.secondaryText; font.pixelSize: 12
                            textFormat: Text.PlainText
                        }
                    }
                    Label {
                        visible: text !== ""
                        text: window.selectedEntry ? window.selectedEntry.error || window.selectedEntry.status : ""
                        color: window.selectedEntry && window.selectedEntry.error ? "#cf7443" : window.secondaryText
                        font.pixelSize: 12; wrapMode: Text.Wrap
                        width: parent.width; textFormat: Text.PlainText
                    }
                    Rectangle { width: parent.width; height: 1; color: window.dividerColor }
                    Repeater {
                        model: window.selectedEntry ? window.selectedEntry.windows : []
                        MenuMetric {
                            required property var modelData
                            width: parent.width
                            metric: modelData
                            quotaDisplay: desktop.settings.quotaDisplay
                            resetDisplay: desktop.settings.resetDisplay
                            showPace: desktop.settings.showPace
                            warningColors: desktop.settings.warningColors
                            notifyThreshold: desktop.settings.notifyThreshold
                            accent: window.meterColor
                            primaryText: window.primaryText
                            secondaryText: window.secondaryText
                            trackColor: window.trackColor
                        }
                    }
                    ColumnLayout {
                        visible: window.selectedEntry && window.selectedEntry.credits !== null &&
                            window.selectedEntry.credits !== undefined
                        width: parent.width
                        spacing: 9
                        Rectangle { Layout.fillWidth: true; height: 1; color: window.dividerColor }
                        Label { text: "Credits"; color: window.primaryText; font.pixelSize: 15; font.weight: Font.DemiBold }
                        Label {
                            text: window.selectedEntry ? String(window.selectedEntry.credits) + " remaining" : ""
                            color: window.secondaryText; font.pixelSize: 13
                        }
                    }
                    ColumnLayout {
                        visible: desktop.settings.showCosts && window.selectedEntry &&
                            ["codex", "claude"].indexOf(window.selectedEntry.provider) >= 0 &&
                            (window.selectedCost !== null || desktop.costBusy || desktop.costError !== "")
                        width: parent.width
                        spacing: 8
                        Rectangle { Layout.fillWidth: true; height: 1; color: window.dividerColor }
                        Label { text: "Cost across accounts"; color: window.primaryText; font.pixelSize: 15; font.weight: Font.DemiBold }
                        Label {
                            text: desktop.costBusy ? "Reading local history…" : desktop.costError
                            visible: text !== ""
                            color: window.secondaryText; font.pixelSize: 12
                            Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                        }
                        Label {
                            text: window.selectedCost ? "Today " + Usage.money(window.selectedCost.today) +
                                "  ·  Last 30 days " + Usage.money(window.selectedCost.month) : ""
                            visible: window.selectedCost !== null
                            color: window.primaryText; font.pixelSize: 13
                            Layout.fillWidth: true; wrapMode: Text.Wrap
                        }
                        Label {
                            visible: window.selectedCost !== null
                            text: window.selectedCost ? Usage.count(window.selectedCost.tokens) + " tokens · " +
                                Usage.provenance(window.selectedCost.provenance) : ""
                            color: window.secondaryText; font.pixelSize: 12
                            Layout.fillWidth: true; wrapMode: Text.Wrap
                        }
                        Repeater {
                            model: window.selectedCost ? [window.selectedCost.error, window.selectedCost.coverage] : []
                            Label {
                                required property string modelData
                                text: modelData; visible: text !== ""
                                color: window.secondaryText; font.pixelSize: 12
                                Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                            }
                        }
                    }
                    Repeater {
                        model: window.selectedEntry ? window.selectedEntry.details : []
                        ColumnLayout {
                            required property var modelData
                            width: parent.width
                            spacing: 6
                            Rectangle { Layout.fillWidth: true; height: 1; color: window.dividerColor }
                            Label {
                                text: modelData.title
                                visible: text !== ""
                                color: window.primaryText
                                font.pixelSize: 14; font.weight: Font.DemiBold
                                Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                            }
                            Repeater {
                                model: modelData.rows
                                Label {
                                    required property var modelData
                                    text: modelData.label + ": " + modelData.value +
                                        (modelData.secondaryValue ? " · " + modelData.secondaryValue : "")
                                    color: window.secondaryText
                                    font.pixelSize: 12
                                    Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText
                                }
                            }
                        }
                    }
                }
                Item { height: 6 }
            }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: window.dividerColor }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.leftMargin: 12; Layout.rightMargin: 12
            Layout.topMargin: 6; Layout.bottomMargin: 8
            spacing: 1
            ActionRow { text: "Usage & Spend…"; onClicked: window.openPage("usage") }
            ActionRow { text: "Settings…"; onClicked: window.openPage("settings") }
            ActionRow { text: "About CodexBar"; onClicked: about.open() }
            ActionRow { text: "Quit"; onClicked: Qt.quit() }
        }
    }
    Dialog {
        id: about
        anchors.centerIn: parent
        modal: true
        title: "About CodexBar"
        standardButtons: Dialog.Ok
        Label { text: "CodexBar Linux " + Qt.application.version; padding: 14 }
    }
    component ActionRow: Button {
        Layout.fillWidth: true
        implicitHeight: 31
        flat: true
        contentItem: Label {
            text: parent.text
            color: window.primaryText
            font.pixelSize: 13
            verticalAlignment: Text.AlignVCenter
            leftPadding: 10
        }
        background: Rectangle {
            radius: 6
            color: parent.hovered || parent.down ? window.hoverColor : "transparent"
        }
    }
}
