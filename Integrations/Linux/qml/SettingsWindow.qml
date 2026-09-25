import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../Shared/Usage.js" as Usage

ApplicationWindow {
    id: window
    title: "Settings"
    width: 680; height: 720
    minimumWidth: 500; minimumHeight: 480
    property string feedback: ""
    property int section: 0
    property var providerOrder: []
    SystemPalette { id: nativePalette }
    palette.window: nativePalette.window
    palette.windowText: nativePalette.windowText
    palette.base: nativePalette.base
    palette.text: nativePalette.text
    palette.button: nativePalette.button
    palette.buttonText: nativePalette.buttonText
    palette.highlight: nativePalette.highlight
    palette.highlightedText: nativePalette.highlightedText
    background: Rectangle { color: nativePalette.window }
    readonly property color secondaryText: Qt.rgba(palette.windowText.r, palette.windowText.g,
        palette.windowText.b, 0.65)
    function moveProvider(index, offset) {
        var order = providerOrder.slice();
        var item = order.splice(index, 1)[0]; order.splice(index + offset, 0, item);
        providerOrder = order;
    }
    onClosing: function(event) { event.accepted = false; hide(); }
    onVisibleChanged: if (visible) load()
    function load() {
        var s = desktop.settings;
        provider.editText = s.provider; source.currentIndex = source.model.indexOf(s.source);
        account.value = s.accountIndex; allAccounts.checked = s.allAccounts;
        identity.checked = s.showIdentity; costs.checked = s.showCosts; status.checked = s.showStatus;
        notices.checked = s.notifications; threshold.value = s.notifyThreshold; interval.value = s.refreshSeconds;
        providerOrder = s.providerOrder.slice();
        quota.currentIndex = quota.model.indexOf(s.quotaDisplay);
        reset.currentIndex = reset.model.indexOf(s.resetDisplay);
        trayStyle.currentIndex = trayStyle.model.indexOf(s.trayStyle);
        theme.checked = s.followOmarchyTheme; pace.checked = s.showPace; warnings.checked = s.warningColors;
        refreshOnOpen.checked = s.refreshOnOpen; compactQuickView.checked = s.compactQuickView;
        tray.checked = s.showTray; executable.text = s.executable; feedback = "";
    }
    Shortcut { sequence: "Escape"; onActivated: window.hide() }
    header: ToolBar {
        Label { anchors.left: parent.left; anchors.leftMargin: 24; anchors.verticalCenter: parent.verticalCenter; text: "Settings"; font.pixelSize: 22; font.bold: true }
        implicitHeight: 64
    }
    ColumnLayout {
        anchors.fill: parent; anchors.margins: 16; spacing: 12
        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            spacing: 14
            Rectangle {
                Layout.preferredWidth: 172; Layout.fillHeight: true
                color: Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.06)
                radius: 10
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 8
                    spacing: 3
                    Label {
                        text: "PREFERENCES"
                        color: window.secondaryText
                        font.pixelSize: 11; font.weight: Font.DemiBold
                        Layout.leftMargin: 9; Layout.topMargin: 8; Layout.bottomMargin: 5
                    }
                    NavigationButton { text: "General"; destination: 0 }
                    NavigationButton { text: "Providers"; destination: 1 }
                    NavigationButton { text: "Advanced"; destination: 2 }
                    Item { Layout.fillHeight: true }
                }
            }
            ScrollView {
                id: scroll
                Layout.fillWidth: true; Layout.fillHeight: true
                contentWidth: availableWidth; clip: true
                ColumnLayout {
                    width: scroll.availableWidth; spacing: 20
                    SettingSection {
                        title: "Provider"; Layout.fillWidth: true; visible: window.section === 1
                        ColumnLayout {
                            anchors.fill: parent; spacing: 10
                            Label { text: "Provider" }
                            ComboBox {
                                id: provider; Layout.fillWidth: true; editable: true
                                model: ["codex", "claude", "both", "enabled", "cursor", "gemini", "copilot", "antigravity", "custom", "all"]
                                validator: RegularExpressionValidator { regularExpression: /^[a-z0-9-]{1,80}$/ }
                            }
                            ColumnLayout {
                                visible: provider.editText === "custom"
                                Layout.fillWidth: true
                                RowLayout {
                                    Layout.fillWidth: true
                                    ComboBox { id: available; model: desktop.providers; textRole: "displayName"; Layout.fillWidth: true }
                                    Button {
                                        text: "Add"
                                        enabled: available.currentIndex >= 0
                                        onClicked: {
                                            var id = desktop.providers[available.currentIndex].provider;
                                            if (window.providerOrder.indexOf(id) < 0) window.providerOrder = window.providerOrder.concat([id]);
                                        }
                                    }
                                }
                                Repeater {
                                    model: window.providerOrder
                                    RowLayout {
                                        required property string modelData
                                        required property int index
                                        Layout.fillWidth: true
                                        Label { text: Usage.providerName(modelData); Layout.fillWidth: true; wrapMode: Text.Wrap }
                                        Button { text: "↑"; Accessible.name: "Move " + modelData + " up"; enabled: index > 0; onClicked: window.moveProvider(index, -1) }
                                        Button { text: "↓"; Accessible.name: "Move " + modelData + " down"; enabled: index < window.providerOrder.length - 1; onClicked: window.moveProvider(index, 1) }
                                        Button { text: "Remove"; onClicked: { var order = window.providerOrder.slice(); order.splice(index, 1); window.providerOrder = order; } }
                                    }
                                }
                            }
                            Label { text: "Choose custom to select and order providers, or enabled to follow your CLI configuration."; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.65 }
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: "Source"; Layout.fillWidth: true }
                                ComboBox { id: source; model: ["auto", "oauth", "cli", "api", "web"] }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: "Account (0 = default)"; Layout.fillWidth: true; wrapMode: Text.Wrap }
                                SpinBox { enabled: !allAccounts.checked && ["custom", "both", "all", "enabled"].indexOf(provider.editText) < 0; id: account; from: 0; to: 999; editable: true }
                            }
                            Option { enabled: ["custom", "both", "all", "enabled"].indexOf(provider.editText) < 0; id: allAccounts; text: "All accounts" }
                            Option { id: identity; text: "Show account identity" }
                            RowLayout {
                                Layout.fillWidth: true
                                ComboBox { id: loginProvider; model: ["codex", "claude"]; Layout.fillWidth: true }
                                Button { text: "Sign in…"; onClicked: { if (desktop.accountAction(loginProvider.currentText, "login")) window.feedback = "Finish signing in in the terminal, then refresh usage."; } }
                                Button { text: "Sign out…"; onClicked: signOut.open() }
                            }
                            Label { text: "Sign-in opens your provider CLI in a terminal. Account selection above only changes displayed usage."; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.65 }
                        }
                    }
                    SettingSection {
                        title: "Updates"; Layout.fillWidth: true; visible: window.section === 0
                        ColumnLayout {
                            anchors.fill: parent; spacing: 10
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: "Refresh every (seconds)"; Layout.fillWidth: true; wrapMode: Text.Wrap }
                                SpinBox { id: interval; from: 60; to: 3600; stepSize: 60; editable: true }
                            }
                            Option { id: refreshOnOpen; text: "Refresh when opening usage" }
                            Option { id: notices; text: "Notify about low quota, resets, and outages" }
                            RowLayout {
                                Layout.fillWidth: true; enabled: notices.checked
                                Label { text: "Remaining quota threshold (%)"; Layout.fillWidth: true; wrapMode: Text.Wrap }
                                SpinBox { id: threshold; from: 1; to: 99; editable: true }
                            }
                            Option { id: status; text: "Service status" }
                        }
                    }
                    SettingSection {
                        title: "Desktop"; Layout.fillWidth: true; visible: window.section === 0
                        ColumnLayout {
                            anchors.fill: parent; spacing: 10
                            Button {
                                text: desktop.launchAtLogin ? "Disable start at login" : "Enable start at login"
                                onClicked: desktop.setLaunchAtLogin(!desktop.launchAtLogin)
                            }
                            Option { id: tray; text: "Tray icon" }
                            Option { id: compactQuickView; text: "Use compact Quick View from the tray" }
                            Label { text: "Optional with the Omarchy widget. CodexBar is also available in the application launcher."; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.65 }
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: "Tray style"; Layout.fillWidth: true }
                                ComboBox { id: trayStyle; model: ["meters", "icon"] }
                            }
                            Option { id: costs; text: "Local spending" }
                        }
                    }
                    SettingSection {
                        title: "Display"; Layout.fillWidth: true; visible: window.section === 0
                        ColumnLayout {
                            anchors.fill: parent; spacing: 10
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: "Quota"; Layout.fillWidth: true }
                                ComboBox { id: quota; model: ["remaining", "used"] }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Label { text: "Reset time"; Layout.fillWidth: true }
                                ComboBox { id: reset; model: ["countdown", "absolute", "both"] }
                            }
                            Option { id: theme; text: "Follow Omarchy theme colors" }
                            Option { id: pace; text: "Show pace" }
                            Option { id: warnings; text: "Highlight low quota" }
                        }
                    }
                    SettingSection {
                        title: "CLI"; Layout.fillWidth: true; visible: window.section === 2
                        ColumnLayout {
                            anchors.fill: parent; spacing: 10
                            Label { text: "Executable" }
                            TextField { id: executable; Layout.fillWidth: true; selectByMouse: true; placeholderText: "codexbar" }
                        }
                    }
                }
            }
        }
        Label { text: desktop.configError || window.feedback; visible: text !== ""; Layout.fillWidth: true; wrapMode: Text.Wrap }
        RowLayout {
            Layout.fillWidth: true
            Label { text: "Closing windows keeps CodexBar running."; Layout.fillWidth: true; wrapMode: Text.Wrap; opacity: 0.65; font.pixelSize: 12 }
            Button { text: "Cancel"; onClicked: window.hide() }
            Button {
                text: "Save"; highlighted: true
                onClicked: {
                    if (desktop.saveSettings({provider: provider.editText.trim(), source: source.currentText,
                        accountIndex: account.value, allAccounts: allAccounts.checked, showIdentity: identity.checked,
                        showCosts: costs.checked, showStatus: status.checked, notifications: notices.checked,
                        notifyThreshold: threshold.value, refreshSeconds: interval.value,
                        providerOrder: window.providerOrder, quotaDisplay: quota.currentText, resetDisplay: reset.currentText,
                        followOmarchyTheme: theme.checked, showPace: pace.checked, warningColors: warnings.checked, trayStyle: trayStyle.currentText,
                        refreshOnOpen: refreshOnOpen.checked, showTray: tray.checked, compactQuickView: compactQuickView.checked,
                        executable: executable.text.trim()})) window.feedback = "Settings saved";
                }
            }
        }
    }
    Dialog {
        id: signOut
        title: "Sign out of " + loginProvider.currentText + "?"
        anchors.centerIn: parent
        modal: true
        standardButtons: Dialog.Cancel | Dialog.Ok
        Label { text: "This signs out the provider CLI on this machine."; wrapMode: Text.Wrap; width: Math.min(window.width - 80, 350) }
        onAccepted: desktop.accountAction(loginProvider.currentText, "logout")
    }
    component Option: CheckBox {
        Layout.fillWidth: true
        contentItem: Text {
            text: parent.text
            font: parent.font
            color: parent.palette.windowText
            leftPadding: parent.indicator.width + parent.spacing
            verticalAlignment: Text.AlignVCenter
            wrapMode: Text.Wrap
        }
    }
    component NavigationButton: Button {
        required property int destination
        Layout.fillWidth: true
        implicitHeight: 36
        flat: true
        contentItem: Label {
            text: parent.text
            color: window.section === parent.destination ? "white" : palette.windowText
            font.pixelSize: 13
            font.weight: window.section === parent.destination ? Font.DemiBold : Font.Normal
            verticalAlignment: Text.AlignVCenter
            leftPadding: 12
        }
        background: Rectangle {
            radius: 7
            color: window.section === parent.destination ? palette.highlight :
                parent.hovered ? Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.08) :
                "transparent"
        }
        onClicked: window.section = destination
    }
    component SettingSection: GroupBox {
        Layout.fillWidth: true
        padding: 14
        label: Label {
            text: parent.title
            color: palette.windowText
            font.pixelSize: 15
            font.weight: Font.DemiBold
            leftPadding: 4
        }
        background: Rectangle {
            y: 8
            height: parent.height - 8
            radius: 10
            color: Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.035)
            border.color: Qt.rgba(palette.windowText.r, palette.windowText.g, palette.windowText.b, 0.13)
        }
    }
}
