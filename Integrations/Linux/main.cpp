#include "DesktopController.h"

#include <QApplication>
#include <QCommandLineParser>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QIcon>
#include <QJsonDocument>
#include <QLocalSocket>
#include <QLockFile>
#include <QMenu>
#include <QPainter>
#include <QRegularExpression>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QStandardPaths>
#include <QSystemTrayIcon>
#include <cstdio>
#include <memory>
#include <unistd.h>

static QByteArray request(const QString &socketPath, const QJsonObject &message) {
    QLocalSocket socket;
    socket.connectToServer(socketPath);
    if (!socket.waitForConnected(500)) return {};
    socket.write(QJsonDocument(message).toJson(QJsonDocument::Compact) + '\n');
    if (!socket.waitForBytesWritten(1000)) return {};
    QElapsedTimer deadline; deadline.start();
    QByteArray reply;
    while (deadline.elapsed() < 3000 && reply.size() < 4 * 1024 * 1024) {
        reply += socket.readAll();
        if (reply.contains('\n')) return reply;
        if (!socket.waitForReadyRead(qMax(1, 3000 - int(deadline.elapsed())))) {
            reply += socket.readAll();
            return reply.contains('\n') ? reply : QByteArray();
        }
    }
    return {};
}

int main(int argc, char **argv) {
    // IPC clients do not load a GUI platform plugin or instantiate a second backend.
    auto application = std::make_unique<QCoreApplication>(argc, argv);
    QCoreApplication::setApplicationName("codexbar-linux");
    QCoreApplication::setApplicationVersion(QStringLiteral(CODEXBAR_DESKTOP_VERSION));
    QCommandLineParser parser;
    parser.setApplicationDescription("CodexBar desktop for Linux · Qt windows and optional tray");
    parser.addHelpOption(); parser.addVersionOption();
    for (const auto &name : {"snapshot", "refresh", "settings", "spending", "usage", "quit", "background", "no-tray"})
        parser.addOption(QCommandLineOption(name, QString("%1 the running desktop app").arg(name)));
    parser.addOption(QCommandLineOption("autostart", "Set login startup: enable, disable, status", "action"));
    parser.addOption(QCommandLineOption("configure", "Update desktop settings through local IPC", "json"));
    parser.addOption(QCommandLineOption("cli", "CodexBar CLI executable for a new instance", "path"));
    parser.process(*application);
    QString command = "usage";
    for (const auto &name : {"background", "usage", "settings", "spending", "refresh", "snapshot", "quit", "configure", "autostart"})
        if (parser.isSet(name)) command = name;
    const bool clientOnly = QStringList{"snapshot", "refresh", "quit", "configure", "autostart"}.contains(command);
    const bool noTray = parser.isSet("no-tray");
    const auto cli = parser.value("cli");
    QJsonObject message{{"command", command}};
    if (command == "autostart") message["action"] = parser.value("autostart");
    if (command == "configure") {
        QJsonParseError error;
        const auto document = QJsonDocument::fromJson(parser.value("configure").toUtf8(), &error);
        if (error.error != QJsonParseError::NoError || !document.isObject()) {
            std::fputs("--configure requires a JSON object\n", stderr); return 2;
        }
        message["settings"] = document.object();
    }
    QString runtime = QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation);
    if (runtime.isEmpty()) runtime = QDir::tempPath() + "/codexbar-" + QString::number(getuid());
    runtime += "/codexbar-linux";
    if (!QDir().mkpath(runtime) || QFileInfo(runtime).ownerId() != getuid() || QFileInfo(runtime).isSymLink()) {
        std::fputs("Cannot create a private runtime directory\n", stderr); return 1;
    }
    QFile::setPermissions(runtime, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    const auto socketPath = runtime + "/desktop.sock";
    auto reply = request(socketPath, message);
    if (!reply.isEmpty()) {
        std::fwrite(reply.constData(), 1, reply.size(), stdout);
        return QJsonDocument::fromJson(reply).object().value("ok").toBool(true) ? 0 : 1;
    }
    if (clientOnly) { std::fputs("CodexBar desktop is not running\n", stderr); return 1; }
    QLockFile lock(runtime + "/desktop.lock");
    if (!lock.tryLock(0)) {
        // Another launch may still be loading QML. Never remove its live socket.
        for (int attempt = 0; attempt < 10 && reply.isEmpty(); ++attempt) {
            usleep(100000); reply = request(socketPath, message);
        }
        if (reply.isEmpty()) { std::fputs("CodexBar is already starting; retry shortly\n", stderr); return 1; }
        return 0;
    }
    application.reset();
    QApplication app(argc, argv);
    app.setApplicationName("codexbar-linux");
    app.setApplicationDisplayName("CodexBar");
    app.setDesktopFileName("com.steipete.CodexBar");
    app.setQuitOnLastWindowClosed(false);
    app.setWindowIcon(QIcon(":/icon.svg"));
    QQuickStyle::setStyle("Fusion");
    DesktopController controller(cli);
    if (!controller.listen(socketPath)) { std::fputs("Cannot start local IPC\n", stderr); return 1; }
    QPalette systemPalette = app.palette();
    bool themeApplied = false;
    auto updateTheme = [&] {
        if (!themeApplied) systemPalette = app.palette();
        QPalette palette = systemPalette;
        themeApplied = false;
        if (controller.settings().value("followOmarchyTheme").toBool()) {
            const auto state = qEnvironmentVariable("XDG_STATE_HOME", QDir::homePath() + "/.local/state");
            QFile file(state + "/omarchy/current/theme/colors.toml");
            if (file.open(QIODevice::ReadOnly) && file.size() <= 65536) {
                const auto text = QString::fromUtf8(file.readAll());
                QMap<QString, QColor> colors;
                const QRegularExpression pattern("^([a-z_]+)\\s*=\\s*[\"'](#[0-9a-fA-F]{6})[\"']", QRegularExpression::MultilineOption);
                auto matches = pattern.globalMatch(text);
                while (matches.hasNext()) { const auto match = matches.next(); colors[match.captured(1)] = QColor(match.captured(2)); }
                if (colors.contains("background") && colors.contains("foreground") && colors.contains("accent")) {
                    themeApplied = true;
                    const auto background = colors["background"], foreground = colors["foreground"];
                    for (const auto role : {QPalette::Window, QPalette::Base, QPalette::Button, QPalette::ToolTipBase}) palette.setColor(role, background);
                    for (const auto role : {QPalette::WindowText, QPalette::Text, QPalette::ButtonText, QPalette::ToolTipText}) palette.setColor(role, foreground);
                    palette.setColor(QPalette::AlternateBase, colors.value("lighter_background", background.lighter(120)));
                    palette.setColor(QPalette::Highlight, colors["accent"]);
                    palette.setColor(QPalette::HighlightedText, background);
                    for (const auto role : {QPalette::WindowText, QPalette::Text, QPalette::ButtonText})
                        palette.setColor(QPalette::Disabled, role, colors.value("dark_foreground", foreground.darker(150)));
                }
            }
        }
        if (app.palette() != palette) app.setPalette(palette);
    };
    QTimer themeTimer;
    QObject::connect(&themeTimer, &QTimer::timeout, &app, updateTheme);
    QObject::connect(&controller, &DesktopController::settingsChanged, &app, updateTheme);
    themeTimer.start(10000); updateTheme();
    QQmlApplicationEngine engine;
    QObject::connect(&engine, &QQmlApplicationEngine::quit, &app, &QCoreApplication::quit);
    engine.rootContext()->setContextProperty("desktop", &controller);
    engine.load(QUrl("qrc:/qml/Main.qml"));
    if (engine.rootObjects().isEmpty()) return 1;
    QSystemTrayIcon tray(QIcon(":/icon.svg"));
    QMenu menu;
    menu.addAction("Usage & Spend…", &controller, [&controller] { controller.showWindow("usage"); });
    menu.addAction("Settings…", &controller, [&controller] { controller.showWindow("settings"); });
    menu.addSeparator();
    menu.addAction("Refresh", &controller, [&controller] { controller.refresh(); controller.refreshCosts(); });
    menu.addAction("Quit CodexBar", &app, &QCoreApplication::quit);
    tray.setContextMenu(&menu);
    QObject::connect(&tray, &QSystemTrayIcon::activated, &controller, [&controller](QSystemTrayIcon::ActivationReason reason) {
        if (reason == QSystemTrayIcon::Trigger || reason == QSystemTrayIcon::DoubleClick) controller.showWindow("usage");
    });
    auto updateTray = [&] {
        tray.setVisible(!noTray && controller.settings().value("showTray").toBool());
        tray.setToolTip("CodexBar · " + (controller.summary().isEmpty() ? "Usage unavailable" : controller.summary()) +
            " · " + controller.settings().value("quotaDisplay").toString() + (controller.stale() ? " · out of date" : ""));
        if (controller.settings().value("trayStyle") == "icon") { tray.setIcon(QIcon(":/icon.svg")); return; }
        QVariantList windows;
        if (!controller.entries().isEmpty()) windows = controller.entries().first().toMap().value("windows").toList();
        QPixmap pixmap(64, 64); pixmap.fill(Qt::transparent);
        QPainter painter(&pixmap); painter.setRenderHint(QPainter::Antialiasing);
        painter.setPen(Qt::NoPen);
        for (int index = 0; index < 2; ++index) {
            const QRectF track(5, 12 + index * 25, 54, 15);
            painter.setBrush(QColor("#777777")); painter.drawRoundedRect(track, 4, 4);
            if (index >= windows.size()) continue;
            const double remaining = qBound(0.0, windows[index].toMap().value("remaining").toDouble(), 100.0);
            const bool warning = controller.settings().value("warningColors").toBool() &&
                remaining <= controller.settings().value("notifyThreshold").toInt();
            painter.setBrush(controller.stale() ? QColor("#aaaaaa") : warning ? QColor("#e59642") : QApplication::palette().highlight().color());
            const double value = controller.settings().value("quotaDisplay") == "used" ? 100 - remaining : remaining;
            painter.drawRoundedRect(QRectF(track.x(), track.y(), track.width() * value / 100, track.height()), 4, 4);
        }
        painter.end(); tray.setIcon(QIcon(pixmap));
    };
    QObject::connect(&controller, &DesktopController::changed, &tray, updateTray);
    QObject::connect(&controller, &DesktopController::settingsChanged, &tray, updateTray);
    updateTray();
    if (command != "background") QTimer::singleShot(0, &controller, [&] { controller.showWindow(command); });
    return app.exec();
}
