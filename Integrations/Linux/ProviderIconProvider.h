#pragma once

#include <QFile>
#include <QFont>
#include <QPainter>
#include <QQuickImageProvider>
#include <QRegularExpression>
#include <QSvgRenderer>

// The shared provider SVGs are white template assets on macOS. Tint them using the
// active Qt palette so they stay legible in both light and dark Linux appearances.
class ProviderIconProvider final : public QQuickImageProvider {
public:
    ProviderIconProvider() : QQuickImageProvider(QQuickImageProvider::Image) {}

    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override {
        const auto provider = id.section('?', 0, 0);
        if (!QRegularExpression("^[a-z0-9-]{1,80}$").match(provider).hasMatch()) return {};
        const auto color = QColor("#" + id.section("color=", 1, 1).section('&', 0, 0));
        const auto dimensions = requestedSize.isValid() ? requestedSize : QSize(36, 36);
        QImage image(dimensions, QImage::Format_ARGB32_Premultiplied);
        image.fill(Qt::transparent);
        QFile icon(":/logos/ProviderIcon-" + provider + ".svg");
        if (icon.open(QIODevice::ReadOnly)) {
            QSvgRenderer svg(icon.readAll());
            if (svg.isValid()) {
                QPainter painter(&image);
                svg.render(&painter);
                painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
                painter.fillRect(image.rect(), color.isValid() ? color : QColor(Qt::black));
                if (size) *size = dimensions;
                return image;
            }
        }
        // Not every provider ships a brand asset yet. Draw the provider initial
        // instead of leaving an empty slot in provider views.
        renderMonogram(image, provider, color.isValid() ? color : QColor(Qt::black));
        if (size) *size = dimensions;
        return image;
    }

private:
    static void renderMonogram(QImage &image, const QString &provider, const QColor &color) {
        QPainter painter(&image);
        painter.setRenderHint(QPainter::Antialiasing, true);
        painter.setPen(Qt::NoPen);
        painter.setBrush(color);
        const auto inset = qMax(2, image.width() / 9);
        painter.drawRoundedRect(image.rect().adjusted(inset, inset, -inset, -inset),
                                image.width() / 6.0, image.width() / 6.0);
        // Keep the initial readable on light and dark accent colours.
        const auto luminance = 0.299 * color.red() + 0.587 * color.green() + 0.114 * color.blue();
        painter.setPen(luminance > 140 ? QColor(Qt::black) : QColor(Qt::white));
        QFont font = painter.font();
        font.setBold(true);
        font.setPixelSize(qMax(8, static_cast<int>(image.height() * 0.46)));
        painter.setFont(font);
        const auto initial = provider.left(1).toUpper();
        painter.drawText(image.rect(), Qt::AlignCenter, initial);
    }
};
