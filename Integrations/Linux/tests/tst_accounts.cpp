#include "../DesktopController.h"

#include <QDir>
#include <QFile>
#include <QStandardPaths>
#include <QTemporaryDir>
#include <QtTest>

class AccountActionsTest : public QObject {
    Q_OBJECT
private slots:
    void onlySupportedActionsReachTheTerminal() {
        QTemporaryDir temporary;
        QVERIFY(temporary.isValid());
        const QByteArray originalPath = qgetenv("PATH");
        qputenv("HOME", temporary.path().toUtf8());
        qputenv("XDG_CONFIG_HOME", (temporary.path() + "/config").toUtf8());
        qputenv("PATH", temporary.path().toUtf8());
        const auto writeExecutable = [&](const QString &name, const QByteArray &content) {
            QFile file(temporary.filePath(name));
            if (!file.open(QIODevice::WriteOnly) || file.write(content) != content.size()) return false;
            return file.setPermissions(QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        };
        QVERIFY(writeExecutable("codex", "#!/bin/sh\nexit 0\n"));
        QVERIFY(writeExecutable("claude", "#!/bin/sh\nexit 0\n"));
        QVERIFY(writeExecutable("fake-cli", "#!/bin/sh\nprintf '[]'\n"));
        qputenv("ACCOUNT_TEST_LOG", temporary.filePath("arguments").toUtf8());
        QVERIFY(writeExecutable("xdg-terminal-exec", "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$ACCOUNT_TEST_LOG\"\n"));
        DesktopController controller(temporary.filePath("fake-cli"));
        QVERIFY(!controller.accountAction("codex;anything", "login"));
        QVERIFY(!controller.accountAction("codex", "unrecognized"));
        QVERIFY(!QFile::exists(temporary.filePath("arguments")));
        QVERIFY(controller.accountAction("claude", "login"));
        QTRY_VERIFY(QFile::exists(temporary.filePath("arguments")));
        QFile file(temporary.filePath("arguments"));
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(file.readAll(), QByteArray("--hold\n--\n") + temporary.filePath("claude").toUtf8() + "\nauth\nlogin\n");
        file.close(); file.remove();
        QVERIFY(controller.accountAction("codex", "logout"));
        QTRY_VERIFY(QFile::exists(temporary.filePath("arguments")));
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(file.readAll(), QByteArray("--hold\n--\n") + temporary.filePath("codex").toUtf8() + "\nlogout\n");
        qputenv("PATH", originalPath);
    }
};

QTEST_GUILESS_MAIN(AccountActionsTest)
#include "tst_accounts.moc"
