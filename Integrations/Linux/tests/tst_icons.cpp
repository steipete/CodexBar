#include "../ProviderIconProvider.h"
#include <QtTest>

class ProviderIconsTest : public QObject {
    Q_OBJECT
private slots:
    void missingAssetUsesVisibleMonogram() {
        ProviderIconProvider provider;
        for (const auto &name : {"openai", "azure-openai", "alibabatokenplan", "moonshot"}) {
            QSize size;
            const auto image = provider.requestImage(QString(name) + "?color=fefefe", &size, QSize(36, 36));
            QVERIFY2(!image.isNull(), name);
            QCOMPARE(size, QSize(36, 36));
            bool foreground = false;
            bool background = false;
            for (int y = 0; y < image.height(); ++y) {
                for (int x = 0; x < image.width(); ++x) {
                    const auto pixel = image.pixelColor(x, y);
                    foreground |= pixel.alpha() > 200 && pixel.lightness() < 40;
                    background |= pixel.alpha() > 200 && pixel.lightness() > 240;
                }
            }
            QVERIFY2(foreground, name);
            QVERIFY2(background, name);
        }
    }
    void existingAssetKeepsTintAndInvalidNamesStayEmpty() {
        ProviderIconProvider provider;
        const auto image = provider.requestImage("codex?color=123456", nullptr, QSize(48, 48));
        QVERIFY(!image.isNull());
        QCOMPARE(image.size(), QSize(48, 48));
        bool tinted = false;
        for (int y = 0; y < image.height(); ++y)
            for (int x = 0; x < image.width(); ++x)
                tinted |= image.pixelColor(x, y) == QColor("#123456");
        QVERIFY(tinted);
        QVERIFY(provider.requestImage("../outside", nullptr, QSize(36, 36)).isNull());
    }
};

QTEST_MAIN(ProviderIconsTest)
#include "tst_icons.moc"
