import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../Shared/Usage.js" as Usage

Frame {
    id: root
    required property var entry
    property color accent: palette.highlight
    padding: 14
    Layout.fillWidth: true
    implicitHeight: content.implicitHeight + topPadding + bottomPadding
    ColumnLayout {
        id: content
        width: parent.width
        spacing: 12
        RowLayout {
            Layout.fillWidth: true
            Label { text: Usage.providerName(root.entry.provider); font.bold: true; font.pixelSize: 18; Layout.fillWidth: true; wrapMode: Text.Wrap }
            Label { text: root.entry.plan || ""; opacity: 0.65; Layout.maximumWidth: root.width / 2; wrapMode: Text.Wrap; textFormat: Text.PlainText }
        }
        Label {
            text: root.entry.accountLabel || ""
            visible: text !== ""
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
        }
        Label { text: root.entry.status || ""; visible: text !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.7 }
        Label { text: root.entry.error || ""; visible: text !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap }
        Repeater {
            model: root.entry.windows
            ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 6
                RowLayout {
                    Layout.fillWidth: true
                    Label { text: modelData.label; Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText }
                    Label { text: Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay) + "% " + (desktop.settings.quotaDisplay === "used" ? "used" : "left"); font.bold: true }
                }
                ProgressBar { Layout.fillWidth: true; from: 0; to: 100; value: Usage.quotaValue(modelData.remaining, desktop.settings.quotaDisplay); palette.highlight: desktop.settings.warningColors && modelData.remaining <= desktop.settings.notifyThreshold ? "#d97732" : root.accent }
                Label { text: Usage.resetText(modelData.resetsAt, clock.now, desktop.settings.resetDisplay); opacity: 0.65; Layout.fillWidth: true; wrapMode: Text.Wrap }
                Label { text: modelData.pace || ""; visible: desktop.settings.showPace && text !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.7 }
            }
        }
        Label { text: "Credits: " + root.entry.credits; visible: root.entry.credits !== null && root.entry.credits !== undefined }
        Repeater {
            model: root.entry.details || []
            ColumnLayout {
                required property var modelData
                Layout.fillWidth: true
                Label { text: modelData.title; visible: text !== ""; font.bold: true }
                Repeater {
                    model: modelData.rows
                    Label {
                        required property var modelData
                        Layout.fillWidth: true
                        text: modelData.label + ": " + modelData.value + (modelData.secondaryValue ? " · " + modelData.secondaryValue : "")
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                    }
                }
                UsageChart { Layout.fillWidth: true; chart: modelData.chart; accent: root.accent }
            }
        }
    }
    Timer { id: clock; property double now: Date.now(); interval: 30000; running: root.visible; repeat: true; onTriggered: now = Date.now() }
}
