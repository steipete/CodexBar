#include "../DesktopController.h"
#include "../FloatingMenu.h"

#include <QGuiApplication>
#include <QScreen>
#include <QTemporaryDir>
#include <QWindow>
#include <QtTest>
#include <memory>

class FloatingGeometryTest : public QObject {
    Q_OBJECT
    QByteArray originalConfig;
    std::unique_ptr<QTemporaryDir> temporary;

private slots:
    void initTestCase() { originalConfig = qgetenv("XDG_CONFIG_HOME"); }
    void init() {
        temporary = std::make_unique<QTemporaryDir>();
        QVERIFY(temporary->isValid());
        qputenv("XDG_CONFIG_HOME", temporary->path().toUtf8());
    }
    void cleanup() { qputenv("XDG_CONFIG_HOME", originalConfig); }

    void compactGeometryDoesNotOverwriteExpandedSize() {
        // No provider program is involved, even if an event loop drains the startup timer.
        DesktopController controller("/bin/false");
        QWindow window;
        window.resize(480, 380);
        QVERIFY(controller.saveSettings({{"floatingCompact", false}}));
        QVERIFY(controller.saveFloatingGeometry(&window));
        QCOMPARE(controller.settings().value("floatingWidth").toInt(), 480);
        QCOMPARE(controller.settings().value("floatingHeight").toInt(), 380);
        QVERIFY(controller.saveSettings({{"floatingCompact", true}}));
        window.resize(306, 48);
        QVERIFY(controller.saveFloatingGeometry(&window));
        QCOMPARE(controller.settings().value("floatingWidth").toInt(), 480);
        QCOMPARE(controller.settings().value("floatingHeight").toInt(), 380);
        QSignalSpy changes(&controller, &DesktopController::settingsChanged);
        QVERIFY(controller.saveFloatingGeometry(&window));
        QCOMPARE(changes.count(), 0); // Unchanged geometry does not write or restart settings flow.
    }

    void offscreenPositionRecoversIntoAvailableScreen() {
        if (QGuiApplication::platformName().startsWith("wayland")) QSKIP("Wayland owns window placement");
        auto *screen = QGuiApplication::primaryScreen();
        QVERIFY(screen);
        DesktopController controller("/bin/false");
        const auto available = screen->availableGeometry();
        QWindow window;
        window.resize(qMin(360, available.width()), qMin(440, available.height()));
        QVERIFY(controller.saveSettings({{"floatingPositionSet", true}, {"floatingX", 100000}, {"floatingY", -100000}}));
        controller.restoreFloatingGeometry(&window);
        QVERIFY(available.contains(window.geometry()));

        const auto position = available.topLeft() + QPoint(10, 10);
        QVERIFY(controller.saveSettings({{"floatingX", position.x()}, {"floatingY", position.y()}}));
        controller.restoreFloatingGeometry(&window);
        QCOMPARE(window.position(), position);

        // A screen-width change must clamp the current position, not jump to old saved coordinates.
        QVERIFY(controller.saveSettings({{"floatingX", 100000}, {"floatingY", -100000}}));
        controller.restoreFloatingGeometry(&window, false);
        QCOMPARE(window.position(), position);

        window.resize(available.width() + 100, available.height() + 100);
        controller.restoreFloatingGeometry(&window);
        QCOMPARE(window.position(), available.topLeft());
    }

    void preferencesRoundTripWithoutAnAccount() {
        {
            DesktopController controller("/bin/false");
            QVERIFY(!controller.settings().value("showFloating").toBool());
            QVERIFY(controller.saveSettings({{"showFloating", true}, {"floatingCompact", false},
                {"floatingOnTop", false}, {"floatingProviders", QStringList{"codex"}},
                {"floatingWidth", 480}, {"floatingHeight", 380}}));
        }
        DesktopController restored("/bin/false");
        QVERIFY(restored.settings().value("showFloating").toBool());
        QVERIFY(restored.settings().value("floatingCompact").toBool());
        QVERIFY(!restored.settings().value("floatingOnTop").toBool());
        QCOMPARE(restored.settings().value("floatingProviders").toStringList(), QStringList{"codex"});
        QCOMPARE(restored.settings().value("floatingWidth").toInt(), 480);
        QCOMPARE(restored.settings().value("floatingHeight").toInt(), 380);
    }

    void nativeMenuIsNotConstrainedToCapsuleHeight() {
        DesktopController controller("/bin/false");
        FloatingMenu menu(controller);
        QWindow capsule;
        capsule.resize(306, 48);
        capsule.show();
        QVERIFY(QTest::qWaitForWindowExposed(&capsule));
        controller.showFloatingMenu(&capsule);
        QTRY_VERIFY(menu.isVisible());
        QCOMPARE(menu.windowHandle()->transientParent(), &capsule);
        QVERIFY(menu.height() > 48);
        QVERIFY(menu.height() >= menu.sizeHint().height());
        QSignalSpy requests(&controller, &DesktopController::floatingActionRequested);
        auto *toggle = menu.findChild<QAction *>("toggleGaugeMode");
        auto *hide = menu.findChild<QAction *>("hideGauge");
        QVERIFY(toggle); QVERIFY(hide);
        QCOMPARE(toggle->text(), QString("Expand"));
        toggle->trigger(); hide->trigger();
        QCOMPARE(requests.count(), 2);
        QCOMPARE(requests.at(0).at(0).toString(), QString("toggle"));
        QCOMPARE(requests.at(1).at(0).toString(), QString("hide"));
        menu.close();
    }
};

QTEST_MAIN(FloatingGeometryTest)
#include "tst_floating.moc"
