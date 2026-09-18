import QtQuick

QtObject {
    id: root
    property Dashboard dashboard: Dashboard {}
    property SettingsWindow preferences: SettingsWindow {}
    property Connections routing: Connections {
        target: desktop
        function onWindowRequested(page) {
            var target = page === "settings" ? root.preferences : root.dashboard;
            if (page !== "settings") root.dashboard.selectedTab = page === "spending" ? 1 : 0;
            target.show();
            target.raise();
            target.requestActivate();
        }
    }
}
