import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const model = vm.createContext({});
vm.runInContext(fs.readFileSync(new URL('../Linux/Shared/Notifications.js', import.meta.url), 'utf8'), model);
const row = (remaining, reset = '2026-01-01', statusLevel = 'none') => ({
    provider: 'codex', windows: [{key: 'primary', label: 'Session', remaining, resetsAt: reset}], statusLevel
});
test('startup is silent and low quota only notifies on crossing', () => {
    const baseline = model.transition({}, [row(50)], 10);
    assert.equal(baseline.events.length, 0);
    const low = model.transition(baseline.state, [row(10)], 10);
    assert.equal(low.events.length, 1);
    assert.equal(low.events[0].kind, 'low');
    assert.equal(model.transition(low.state, [row(5)], 10).events.length, 0);
});
test('reset and outage transitions notify once', () => {
    const old = model.transition({}, [row(5)], 10).state;
    const reset = model.transition(old, [row(100, '2026-01-02', 'major')], 10);
    assert.deepEqual(Array.from(reset.events, e => e.kind), ['reset', 'status']);
    assert.equal(model.transition(reset.state, [row(100, '2026-01-02', 'major')], 10).events.length, 0);
});
test('provider errors and ambiguous account ordering cannot generate alerts', () => {
    const old = model.transition({}, [row(50)], 10).state;
    assert.equal(model.transition(old, [{...row(0), failed: true}], 10).events.length, 0);
    assert.equal(model.transition(old, [row(50), row(0)], 10).events.length, 0);
});
test('provider ordering does not affect quota transitions', () => {
    const claude = {...row(50), provider: 'claude'};
    const old = model.transition({}, [row(50), claude], 10).state;
    const next = model.transition(old, [claude, row(5)], 10);
    assert.equal(next.events.length, 1);
    assert.equal(next.events[0].provider, 'codex');
});
test('copied summaries omit account identity and credentials', () => {
    const summary = model.summary([{...row(50), accountLabel: 'private@example.com', token: 'secret'}]);
    assert.equal(summary, 'CODEX\nSession: 50% remaining');
});
