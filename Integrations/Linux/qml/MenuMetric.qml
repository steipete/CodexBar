import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../Shared/Usage.js" as Usage

ColumnLayout {
    id: root
    required property var metric
    property string quotaDisplay: "used"
    property string resetDisplay: "countdown"
    property bool showPace: true
    property bool warningColors: true
    property int notifyThreshold: 20
    property color accent
    property color primaryText
    property color secondaryText
    property color trackColor
    readonly property int amount: Usage.quotaValue(metric.remaining, quotaDisplay)
    readonly property bool warning: warningColors && metric.remaining <= notifyThreshold
    spacing: 6
    Layout.fillWidth: true

    RowLayout {
        Layout.fillWidth: true
        spacing: 8
        Label {
            text: root.metric.label
            color: root.primaryText
            font.pixelSize: 15
            font.weight: Font.DemiBold
            elide: Text.ElideRight
            Layout.fillWidth: true
            textFormat: Text.PlainText
        }
        Label {
            text: Usage.resetText(root.metric.resetsAt, clock.now, root.resetDisplay)
            color: root.secondaryText
            font.pixelSize: 12
            horizontalAlignment: Text.AlignRight
            wrapMode: Text.Wrap
            Layout.maximumWidth: root.width * 0.48
            textFormat: Text.PlainText
        }
    }
    Rectangle {
        id: track
        Layout.fillWidth: true
        height: 7
        radius: height / 2
        color: root.trackColor
        Accessible.role: Accessible.ProgressBar
        Accessible.name: root.metric.label + ": " + root.amount + "% " +
            (root.quotaDisplay === "used" ? "used" : "left")
        Rectangle {
            width: track.width * Math.max(0, Math.min(100, root.amount)) / 100
            height: parent.height
            radius: parent.radius
            color: root.warning ? "#d9874a" : root.accent
        }
    }
    Label {
        Layout.fillWidth: true
        text: root.amount + "% " + (root.quotaDisplay === "used" ? "used" : "left")
        color: root.primaryText
        font.pixelSize: 13
    }
    Label {
        Layout.fillWidth: true
        visible: root.showPace && text !== ""
        text: root.metric.pace || ""
        color: root.secondaryText
        font.pixelSize: 12
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
    }
    Timer {
        id: clock
        property double now: Date.now()
        interval: 30000
        running: root.visible
        repeat: true
        onTriggered: now = Date.now()
    }
}
