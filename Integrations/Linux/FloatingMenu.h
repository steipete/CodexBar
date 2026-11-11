#pragma once

#include "DesktopController.h"
#include <QAction>
#include <QCoreApplication>
#include <QCursor>
#include <QMenu>
#include <QWindow>

// Qt 6.4 Quick menus are constrained to their parent window. A native popup
// remains fully usable outside the 48px capsule without another QML dependency.
class FloatingMenu final : public QMenu {
public:
    explicit FloatingMenu(DesktopController &controller) {
        auto *compact = addAction("Expand", &controller, [&controller] {
            emit controller.floatingActionRequested("toggle");
        });
        compact->setObjectName("toggleGaugeMode");
        auto *onTop = addAction("Always on top");
        onTop->setCheckable(true);
        connect(onTop, &QAction::triggered, &controller, [&controller](bool enabled) {
            controller.saveSettings({{"floatingOnTop", enabled}});
        });
        auto *refresh = addAction("Refresh usage", &controller, [&controller] { controller.refresh(); });
        addSeparator();
        addAction("Usage & Spend…", &controller, [&controller] { controller.showWindow("usage"); });
        addAction("Settings…", &controller, [&controller] { controller.showWindow("settings"); });
        auto *hide = addAction("Hide gauge", &controller, [&controller] {
            emit controller.floatingActionRequested("hide");
        });
        hide->setObjectName("hideGauge");
        addSeparator();
        addAction("Quit CodexBar", QCoreApplication::instance(), &QCoreApplication::quit);
        connect(this, &QMenu::aboutToShow, this, [&controller, compact, onTop, refresh] {
            compact->setText(controller.settings().value("floatingCompact").toBool() ? "Expand" : "Collapse");
            onTop->setChecked(controller.settings().value("floatingOnTop").toBool());
            refresh->setEnabled(!controller.busy());
        });
        connect(&controller, &DesktopController::floatingMenuRequested, this, [this](QWindow *window) {
            // Give Wayland a real transient parent instead of a parentless popup.
            winId();
            windowHandle()->setTransientParent(window);
            popup(QCursor::pos());
        });
    }
};