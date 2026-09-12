import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var chart
    property color accent: colors.highlight
    property int selected: -1
    readonly property var points: chart ? chart.points : []
    readonly property real minimum: Math.min(0, ...points.map(p => p.value))
    readonly property real maximum: Math.max(1, ...points.map(p => p.value))
    visible: points.length > 0
    spacing: 8
    SystemPalette { id: colors }
    Label { text: root.chart ? root.chart.title : ""; Layout.fillWidth: true; wrapMode: Text.Wrap; textFormat: Text.PlainText }
    Canvas {
        id: canvas
        Layout.fillWidth: true
        implicitHeight: 110
        onWidthChanged: requestPaint()
        onPaint: {
            var ctx = getContext("2d"); ctx.reset();
            if (!root.points.length) return;
            var step = width / root.points.length;
            var range = root.maximum - root.minimum;
            var baseline = height * root.maximum / range;
            ctx.strokeStyle = colors.text; ctx.globalAlpha = 0.2;
            ctx.beginPath(); ctx.moveTo(0, baseline); ctx.lineTo(width, baseline); ctx.stroke();
            ctx.globalAlpha = 1; ctx.fillStyle = root.accent; ctx.strokeStyle = root.accent; ctx.lineWidth = 2;
            ctx.beginPath();
            root.points.forEach(function(point, index) {
                var y = height * (root.maximum - point.value) / range;
                if (root.chart.kind === "line") {
                    if (index === 0) ctx.moveTo(step * (index + 0.5), y);
                    else ctx.lineTo(step * (index + 0.5), y);
                    if (root.points.length === 1) ctx.fillRect(step / 2 - 2, y, 4, 4);
                } else {
                    var barWidth = Math.max(1, Math.min(20, step - 3));
                    ctx.fillRect(step * (index + 0.5) - barWidth / 2, Math.min(y, baseline), barWidth, Math.max(1, Math.abs(baseline - y)));
                }
            });
            if (root.chart.kind === "line") ctx.stroke();
        }
        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            onPositionChanged: function(mouse) { root.selected = Math.min(root.points.length - 1, Math.floor(mouse.x / width * root.points.length)); }
            onExited: root.selected = -1
        }
    }
    onChartChanged: { selected = -1; canvas.requestPaint(); }
    onAccentChanged: canvas.requestPaint()
    Label {
        Layout.fillWidth: true
        wrapMode: Text.Wrap
        textFormat: Text.PlainText
        opacity: 0.65
        text: root.selected >= 0 && root.selected < root.points.length ?
            root.points[root.selected].label + " · " + root.points[root.selected].value.toFixed(2) + " " + root.chart.unit :
            (root.points.length ? root.points[0].label + " → " + root.points[root.points.length - 1].label : "")
    }
}
