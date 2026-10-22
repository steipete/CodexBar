import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const model = vm.createContext({});
vm.runInContext(fs.readFileSync(new URL('../Linux/Shared/Notifications.js', import.meta.url), 'utf8'), model);
const usage = vm.createContext({});
vm.runInContext(fs.readFileSync(new URL('../Linux/Shared/Usage.js', import.meta.url), 'utf8'), usage);
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

test('scoped IDs cannot alias standard quota or status notification state', () => {
    const entries = (low = false, reversed = false) => {
        const extras = ['primary', 'status'].map(id => ({id, title: 'Scoped ' + id,
            window: {usedPercent: low ? 95 : 50, windowMinutes: 10080}}));
        if (reversed) extras.reverse();
        return usage.rows(JSON.stringify([{provider: 'claude', status: {indicator: 'none'}, usage: {
            primary: {usedPercent: 95, windowMinutes: 300}, extraRateWindows: extras}}]));
    };
    const baseline = model.transition({}, entries(), 10);
    assert.equal(baseline.events.length, 0);
    const repeated = model.transition(baseline.state, entries(false, true), 10);
    assert.equal(repeated.events.length, 0);
    const low = model.transition(repeated.state, entries(true), 10);
    assert.deepEqual(Array.from(low.events, event => event.message), [
        'Scoped primary: 5% quota remaining.', 'Scoped status: 5% quota remaining.'
    ]);
});

test('scoped clipboard summaries omit unmeasured windows and private titles', () => {
    const entries = usage.rows(JSON.stringify([{provider: 'claude', usage: {
        primary: {usedPercent: 0, isSyntheticPlaceholder: true},
        extraRateWindows: [
            {id: 'private@example.invalid', title: 'Scoped (private@example.invalid)',
                window: {usedPercent: 93, windowMinutes: 10080}},
            {id: 'billing', title: 'Billing', usageKnown: false, window: {usedPercent: 100}}
        ]}}]), true);
    assert.equal(model.summary(entries), 'CLAUDE\nScoped [hidden email]: 7% remaining');
});

// Antigravity copies the tightest pool of each family into its positional windows, so which
// pool leads can change between polls.
const antigravity = (geminiSession, geminiWeekly, claudeSession) => {
    const pool = (remaining, windowMinutes) => ({usedPercent: 100 - remaining, windowMinutes, resetsAt: '2026-09-21T01:00:00Z'});
    const pools = {geminiSession: pool(geminiSession, 300), geminiWeekly: pool(geminiWeekly, 10080),
        claudeSession: pool(claudeSession, 300)};
    const tightest = (a, b) => a.usedPercent >= b.usedPercent ? a : b;
    const summary = (id, title, window) => ({id: 'antigravity-quota-summary-' + id, title, usageKnown: true, window});
    return usage.rows(JSON.stringify([{provider: 'antigravity', usage: {
        primary: tightest(pools.geminiSession, pools.geminiWeekly), secondary: pools.claudeSession,
        extraRateWindows: [summary('gemini-5h', 'Gemini 5-hour', pools.geminiSession),
            summary('gemini-weekly', 'Gemini weekly', pools.geminiWeekly),
            summary('claude-5h', 'Claude/GPT 5-hour', pools.claudeSession)]}}]), false);
};

test('a pool that becomes its family representative keeps its alert history', () => {
    const baseline = model.transition({}, antigravity(20, 5, 90), 10);
    const low = model.transition(baseline.state, antigravity(4, 5, 90), 10);
    assert.deepEqual(Array.from(low.events, event => event.message), ['Gemini 5-hour: 4% quota remaining.']);
});

test('families reporting equal values keep their own titles', () => {
    const baseline = model.transition({}, antigravity(5, 0, 20), 10);
    const low = model.transition(baseline.state, antigravity(5, 0, 5), 10);
    assert.deepEqual(Array.from(low.events, event => event.message), ['Claude/GPT 5-hour: 5% quota remaining.']);
});

test('a stable-ID representative with a general title emits one alert per allowance crossing', () => {
    const entries = usedPercent => {
        const window = {usedPercent, windowMinutes: 10080, resetsAt: '2030-01-01T00:00:00Z'};
        return usage.rows(JSON.stringify([{provider: 'antigravity', usage: {
            primary: window, extraRateWindows: [
                {id: 'antigravity-quota-summary-gemini-weekly', title: 'General models weekly', window},
                {id: 'antigravity-quota-summary-gemini-synthetic-limited-weekly', title: 'General models weekly',
                    window: {...window, usedPercent: 100}}
            ]}}]));
    };
    const baseline = model.transition({}, entries(80), 10);
    assert.equal(baseline.events.length, 0);
    const low = model.transition(baseline.state, entries(95), 10);
    assert.deepEqual(Array.from(low.events, event => event.message), ['General models weekly: 5% quota remaining.']);
    assert.deepEqual(Object.keys(low.state), [
        'antigravity/extra:antigravity-quota-summary-gemini-weekly',
        'antigravity/extra:antigravity-quota-summary-gemini-synthetic-limited-weekly']);
    assert.equal(model.transition(low.state, entries(95), 10).events.length, 0);
});
