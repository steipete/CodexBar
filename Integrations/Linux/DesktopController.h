#pragma once

#include <QJSEngine>
#include <QJsonObject>
#include <QLocalServer>
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QVariant>

class DesktopController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList providers READ providers NOTIFY settingsChanged)
    Q_PROPERTY(bool launchAtLogin READ launchAtLogin NOTIFY settingsChanged)
    Q_PROPERTY(QVariantList entries READ entries NOTIFY changed)
    Q_PROPERTY(QVariantList spending READ spending NOTIFY changed)
    Q_PROPERTY(QVariantMap settings READ settings NOTIFY settingsChanged)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(QString costError READ costError NOTIFY changed)
    Q_PROPERTY(QString configError READ configError NOTIFY settingsChanged)
    Q_PROPERTY(QString summary READ summary NOTIFY changed)
    Q_PROPERTY(bool busy READ busy NOTIFY changed)
    Q_PROPERTY(bool costBusy READ costBusy NOTIFY changed)
    Q_PROPERTY(bool stale READ stale NOTIFY changed)
    Q_PROPERTY(QString updated READ updated NOTIFY changed)

public:
    explicit DesktopController(const QString &cliOverride, QObject *parent = nullptr);
    ~DesktopController() override;
    bool listen(const QString &socket);
    QVariantList providers() const { return m_providers; }
    bool launchAtLogin() const;
    Q_INVOKABLE bool setLaunchAtLogin(bool enabled);
    Q_INVOKABLE bool accountAction(const QString &provider, const QString &action);
    QVariantList entries() const { return m_entries; }
    QVariantList spending() const { return m_spending; }
    QVariantMap settings() const { return m_settings; }
    QString error() const { return m_error; }
    QString costError() const { return m_costError; }
    QString configError() const { return m_configError; }
    QString summary() const { return m_summary; }
    bool busy() const { return m_usageBatch || m_usage.state() != QProcess::NotRunning; }
    bool costBusy() const { return m_cost.state() != QProcess::NotRunning; }
    bool stale() const;
    QString updated() const;
    Q_INVOKABLE void refresh();
    Q_INVOKABLE void refreshCosts();
    Q_INVOKABLE void showWindow(const QString &page);
    Q_INVOKABLE bool saveSettings(const QVariantMap &changes);
    Q_INVOKABLE void copySummary();
    QJsonObject snapshot() const;

signals:
    void changed();
    void settingsChanged();
    void windowRequested(const QString &page);

private:
    QJSEngine m_engine;
    QJSValue m_usageModel, m_noticeModel, m_noticeState;
    QProcess m_usage, m_cost, m_catalog;
    QVariantList m_providers, m_batchEntries;
    QStringList m_pendingProviders;
    QString m_currentProvider;
    bool m_usageBatch = false, m_batchFailed = false;
    void nextProvider();
    void loadProviders();
    QTimer m_poll, m_clock;
    QLocalServer m_server;
    QVariantMap m_settings;
    QVariantList m_entries, m_spending;
    QString m_configPath, m_error, m_costError, m_configError, m_summary;
    qint64 m_updated = 0, m_costUpdated = 0;
    int m_generation = 0;
    bool m_configBlocked = false;
    void loadSettings(const QString &cliOverride);
    bool validate(QVariantMap &settings);
    void probe(QProcess &process, const QStringList &command, bool cost);
    void updateNotifications(const QVariantList &entries);
    QJSValue call(const QJSValue &module, const QString &function, const QJSValueList &args) const;
};
