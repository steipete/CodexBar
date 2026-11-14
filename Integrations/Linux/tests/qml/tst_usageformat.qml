import QtQuick
import QtTest
import "../../Shared/Usage.js" as Usage

TestCase {
    name: "UsageFormat"
    function test_tokenGrouping_data() {
        return [
            {tag: "billions", value: 2992687053, expected: "2,992,687,053"},
            {tag: "input", value: 2979214406, expected: "2,979,214,406"},
            {tag: "output", value: 13472647, expected: "13,472,647"},
            {tag: "small", value: 999, expected: "999"},
            {tag: "boundary", value: 1000, expected: "1,000"},
            {tag: "rounding", value: 999.6, expected: "1,000"},
            {tag: "zero", value: 0, expected: "0"},
            {tag: "missing", value: null, expected: "—"}
        ];
    }
    function test_tokenGrouping(data) {
        compare(Usage.count(data.value), data.expected);
    }
}
