import QtQuick
import QtQuick.Controls
import QtTest
import "../../qml" as Desktop
TestCase {
    name: "UsageCardLayout"
    when: windowShown
    width: 820; height: 700
    QtObject { id: desktop; property var settings: ({showPace: true}) }
    Component { id: card; Desktop.UsageCard {} }
    function findText(item, text) {
        if (item.text === text) return item;
        for (var i = 0; i < item.children.length; ++i) {
            var found = findText(item.children[i], text);
            if (found) return found;
        }
        return null;
    }
    function test_planStaysHorizontal() {
        for (var width of [440, 780]) {
            var item = createTemporaryObject(card, this, {width: width,
                entry: {provider: "codex", plan: "prolite", windows: []}});
            verify(item);
            wait(30);
            var plan = findText(item, "prolite");
            verify(plan);
            verify(plan.width >= plan.implicitWidth);
            compare(plan.lineCount, 1);
            verify(plan.mapToItem(item, 0, 0).x + plan.width <= item.width);
        }
    }
}
