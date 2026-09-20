import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const model = vm.createContext({});
vm.runInContext(fs.readFileSync(new URL('../Linux/Shared/Usage.js', import.meta.url), 'utf8'), model);
test('quota is clamped, missing quota stays unknown', () => {
    assert.equal(model.remaining({usedPercent: 28}), 72);
    assert.equal(model.remaining({usedPercent: 150}), 0);
    assert.equal(model.remaining({usedPercent: -5}), 100);
    for (const value of [null, {}, {usedPercent: null}, {usedPercent: '12'}, {usedPercent: Infinity}])
        assert.equal(model.remaining(value), null);
});
test('partial provider failures preserve healthy rows without leaking raw errors or identity', () => {
    const rows = model.rows(JSON.stringify([
        {provider: 'codex', usage: {primary: {usedPercent: 28, windowMinutes: 300}, identity: {accountEmail: 'private@example.com'}}},
        {provider: 'claude', error: {message: 'secret upstream response'}}
    ]));
    assert.equal(model.summary(rows), 'CX 72%  ·  CL —');
    assert.equal(rows[0].windows[0].label, '5 hour');
    assert.ok(rows[1].error);
    assert.ok(!JSON.stringify(rows).includes('secret'));
    assert.ok(!JSON.stringify(rows).includes('private'));
});
test('malformed and unrecognized responses cannot replace the last good snapshot', () => {
    for (const value of ['', '[]', '{}', 'null', '[null]', 'oops'])
        assert.throws(() => model.rows(value));
});
test('reset countdown handles invalid and elapsed timestamps', () => {
    const now = Date.parse('2026-01-01T00:00:00Z');
    assert.equal(model.resetLabel('bad', now), 'Reset time unavailable');
    assert.equal(model.resetLabel('2025-12-31T23:00:00Z', now), 'Reset due · refresh to update');
    assert.equal(model.resetLabel('2026-01-01T01:30:00Z', now), 'Resets in 1h 30m');
});
test('account selection is scoped to a single provider and arguments never use a shell', () => {
    const command = model.command({provider: 'both', allAccounts: true, accountIndex: 2});
    assert.ok(!command.includes('--all-accounts'));
    assert.ok(!command.includes('--account-index'));
    assert.ok(!model.command({provider: 'enabled'}).includes('--provider'));
    const single = model.command({provider: 'codex', allAccounts: true, source: 'oauth', executable: '/a path/codexbar'});
    assert.ok(single.includes('--all-accounts'));
    assert.ok(single.includes('/a path/codexbar'));
    assert.ok(single.includes('oauth'));
    assert.ok(!model.command({accountIndex: '2;bad'}).includes('--account-index'));
});
test('identity is opt-in and stays within its provider row', () => {
    const input = JSON.stringify([{provider: 'codex', usage: {identity: {accountEmail: 'one@example.com', loginMethod: 'pro'}}},
        {provider: 'claude', usage: {}}]);
    assert.equal(model.rows(input)[0].accountLabel, '');
    assert.equal(model.rows(input, true)[0].accountLabel, 'one@example.com');
    assert.equal(model.rows(input, true)[1].accountLabel, '');
    assert.equal(model.rows(input, true)[1].plan, '');
});
test('cost history preserves unknown amounts and uses the actual calendar day', () => {
    const input = JSON.stringify([{provider: 'codex', sessionCostUSD: 99, last30DaysCostUSD: 5,
        historyCoverageIsEstablished: true, daily: [{date: '2026-01-01', totalCost: 5}, {date: '2026-01-02', totalCost: null}]}]);
    const row = model.costs(input, '2026-01-02')[0];
    assert.equal(row.today, null);
    assert.equal(row.month, 5);
    assert.equal(row.chart.points.length, 1);
    assert.equal(model.costs(input, '2026-01-03')[0].today, 0);
    assert.equal(model.money(null), 'Unavailable');
    assert.equal(model.money(0), '$0.00');
});
test('generic charts bound data and keep negative values', () => {
    const result = model.chart({kind: 'line', points: [{label: 'a', value: -4}, {label: 'b', value: null}, {label: 'c', value: Infinity}]});
    assert.equal(result.points.length, 1);
    assert.equal(result.points[0].value, -4);
    assert.equal(model.chart(null), null);
    assert.equal(model.count(5358220), '5,358,220');
    assert.equal(model.count(null), '—');
});
test('provider detail rows redact emails unless explicitly enabled', () => {
    const input = JSON.stringify({provider: 'codex', usage: {details: [{rows: [{label: 'Account', value: 'private@example.com'}]}]}});
    assert.equal(model.rows(input)[0].details[0].rows[0].value, '[hidden email]');
    assert.equal(model.rows(input, true)[0].details[0].rows[0].value, 'private@example.com');
});

test('display preferences keep underlying quota and reset data intact', () => {
    assert.equal(model.quotaValue(60, 'used'), 40);
    assert.equal(model.quotaValue(60, 'remaining'), 60);
    assert.equal(model.resetText('invalid', 0, 'absolute'), 'Reset time unavailable');
    const time = '2030-01-01T00:00:00Z';
    assert.ok(model.resetText(time, 0, 'absolute').startsWith('Resets '));
    assert.ok(model.resetText(time, 0, 'both').includes(' · '));
});

const lanes = (windows, pace) => model.rows(JSON.stringify([{provider: 'codex', usage: windows, pace}]));
const session = {usedPercent: 63, windowMinutes: 300, resetsAt: '2030-01-01T00:00:00Z'};
const weekly = {usedPercent: 39, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'};

test('bar shows session quota, weekly quota, then the weekly pace', () => {
    const rows = lanes({primary: session, secondary: weekly}, {secondary: {deltaPercent: 14, summary: '14% in deficit'}});
    assert.equal(model.barLabel(rows, 'remaining'), '5H 37% · 7D 61% · +14%');
    assert.equal(model.barLabel(rows, 'used'), '5H 63% · 7D 39% · +14%');
    assert.equal(rows[0].windows[1].minutes, 10080);
});
test('a weekly reserve keeps its negative sign and an exact pace reads as zero', () => {
    assert.equal(model.barLabel(lanes({primary: session, secondary: weekly},
        {secondary: {deltaPercent: -8}}), 'remaining'), '5H 37% · 7D 61% · -8%');
    assert.equal(model.barLabel(lanes({secondary: weekly}, {secondary: {deltaPercent: 0.4}}), 'remaining'), '7D 61% · 0%');
});
test('pace always describes the weekly window, never the most constrained lane', () => {
    const rows = lanes({primary: session, secondary: weekly},
        {primary: {deltaPercent: 31}, secondary: {deltaPercent: -8}});
    assert.equal(model.barLabel(rows, 'remaining'), '5H 37% · 7D 61% · -8%');
});
test('a provider without a session window omits that segment and its separator', () => {
    const label = model.barLabel(lanes({secondary: weekly}, {secondary: {deltaPercent: 14}}), 'remaining');
    assert.equal(label, '7D 61% · +14%');
    assert.ok(!label.includes('5H'));
    assert.ok(!label.startsWith(' ·'));
});
test('a provider without a weekly window shows the session lane alone', () => {
    const label = model.barLabel(lanes({primary: session}, {primary: {deltaPercent: 14}}), 'remaining');
    assert.equal(label, '5H 37%');
    assert.ok(!label.includes('·'));
    assert.ok(!label.includes('—'));
});
test('an unavailable weekly pace is omitted entirely rather than shown as a dash', () => {
    assert.equal(model.barLabel(lanes({secondary: weekly}, null), 'remaining'), '7D 61%');
    for (const value of [{}, {deltaPercent: null}, {deltaPercent: 'nope'}, {deltaPercent: Infinity}])
        assert.equal(model.barLabel(lanes({secondary: weekly}, {secondary: value}), 'remaining'), '7D 61%');
});
test('missing quota values never produce empty segments or stray separators', () => {
    assert.equal(model.barLabel(lanes({primary: {usedPercent: null, windowMinutes: 300}, secondary: weekly},
        {secondary: {deltaPercent: 14}}), 'remaining'), '7D 61% · +14%');
    assert.equal(model.barLabel(lanes({}, null), 'remaining'), '—');
    assert.equal(model.barLabel([], 'remaining'), '');
    for (const label of [model.barLabel(lanes({secondary: weekly}, null), 'remaining'), model.barLabel(lanes({}, null), 'remaining')])
        assert.ok(!/(^|\s)·\s*·|·\s*$|^\s*·/.test(label));
});
test('an unreported cadence keeps its own lane rather than borrowing weekly pace', () => {
    const monthly = {usedPercent: 25, windowMinutes: 43200, resetsAt: '2030-01-02T00:00:00Z'};
    assert.equal(model.barLabel(lanes({primary: monthly}, {primary: {deltaPercent: 14}}), 'remaining'), '30D 75%');
    assert.equal(model.barLabel(lanes({primary: {usedPercent: 25}}, null), 'remaining'), 'Session 75%');
});
test('a failed provider row keeps the healthy provider labelled and never fabricates pace', () => {
    const rows = model.rows(JSON.stringify([
        {provider: 'codex', usage: {secondary: weekly}, pace: {secondary: {deltaPercent: 14}}},
        {provider: 'claude', error: {message: 'secret upstream response'}}]));
    assert.equal(model.barLabel(rows, 'remaining'), 'CX 7D 61% · +14%  ·  CL —');
    assert.ok(!JSON.stringify(rows).includes('secret'));
});

const scopedEntry = {provider: 'claude', usage: {
    primary: {usedPercent: 21, windowMinutes: 300, resetsAt: '2026-09-18T18:00:00Z'},
    secondary: {usedPercent: 71, windowMinutes: 10080, resetsAt: '2026-09-21T09:00:00Z'},
    extraRateWindows: [{id: 'claude-weekly-scoped-fable', title: 'Fable only',
        window: {usedPercent: 93, windowMinutes: 10080, resetsAt: '2026-09-21T09:00:00Z'}}]}};

test('extra rate windows are appended after the standard lanes so the real weekly lane wins a cadence lookup', () => {
    const row = model.rows(JSON.stringify([scopedEntry]))[0];
    assert.deepEqual([...row.windows.map(window => window.key)],
        ['primary', 'secondary', 'claude-weekly-scoped-fable']);
    assert.deepEqual({...row.windows[2]},
        {key: 'claude-weekly-scoped-fable', label: 'Fable only', minutes: 10080, remaining: 7,
            resetsAt: '2026-09-21T09:00:00Z', pace: '', paceDelta: null, scoped: true});
    assert.equal(row.error, '');
});
test('an extra rate window with an unusable quota is skipped', () => {
    const entry = {provider: 'claude', usage: {extraRateWindows: [
        {id: 'bad', title: 'Broken', window: {usedPercent: '93', windowMinutes: 10080}},
        {id: 'good', title: 'Fable only', window: {usedPercent: 93, windowMinutes: 10080}}]}};
    const row = model.rows(JSON.stringify([entry]))[0];
    assert.deepEqual([...row.windows.map(window => window.key)], ['good']);
});
test('an extra rate window without a title still renders a duration label', () => {
    const entry = {provider: 'claude', usage: {extraRateWindows: [
        {id: 'a', title: '   ', window: {usedPercent: 50, windowMinutes: 10080}},
        {id: 'b', window: {usedPercent: 50, windowMinutes: 300}},
        {id: 'c', window: {usedPercent: 50}}]}};
    const row = model.rows(JSON.stringify([entry]))[0];
    assert.deepEqual([...row.windows.map(window => window.label)], ['7 day', '5 hour', 'Additional']);
});
test('extra rate window titles are redacted even when identity display is enabled', () => {
    const entry = {provider: 'claude', usage: {extraRateWindows: [
        {id: 'scoped', title: 'Fable (private@example.com)', window: {usedPercent: 93, windowMinutes: 10080}}]}};
    const input = JSON.stringify([entry]);
    // These labels are exported over IPC, whose contract excludes account identity
    // unconditionally, so the display preference must not be able to widen it.
    assert.equal(model.rows(input)[0].windows[0].label, 'Fable [hidden email]');
    assert.equal(model.rows(input, true)[0].windows[0].label, 'Fable [hidden email]');
});
test('extras without a usable window payload are skipped', () => {
    const entry = {provider: 'claude', usage: {extraRateWindows: [
        null, {id: 'no-window', title: 'No window'}, {id: 'no-percent', window: {windowMinutes: 60}},
        {id: 'good', title: 'Fable only', window: {usedPercent: 93, windowMinutes: 10080}}]}};
    const row = model.rows(JSON.stringify([entry]))[0];
    assert.deepEqual([...row.windows.map(window => window.key)], ['good']);
    assert.equal(row.error, '');
});
test('the extra-window cap counts displayed lanes, not skipped ones', () => {
    const unusable = Array.from({length: 8}, (_, index) => (
        {id: 'junk-' + index, title: 'Junk', window: {usedPercent: null}}));
    const entry = {provider: 'claude', usage: {extraRateWindows: [...unusable,
        {id: 'claude-weekly-scoped-fable', title: 'Fable only', window: {usedPercent: 93, windowMinutes: 10080}}]}};
    assert.deepEqual([...model.rows(JSON.stringify([entry]))[0].windows.map(window => window.key)],
        ['claude-weekly-scoped-fable']);
});
test('extra rate windows are capped at eight per provider', () => {
    const extras = Array.from({length: 10}, (_, index) => (
        {id: 'extra-' + index, title: 'Lane ' + index, window: {usedPercent: index, windowMinutes: 60}}));
    const row = model.rows(JSON.stringify([{provider: 'claude', usage: {extraRateWindows: extras}}]))[0];
    assert.equal(row.windows.length, 8);
});

test('a scoped cap appears in the bar by name, after the weekly lane and before the pace', () => {
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        primary: session, secondary: weekly,
        extraRateWindows: [{id: 'claude-weekly-scoped-fable', title: 'Fable only',
            window: {usedPercent: 93, windowMinutes: 10080}}]},
        pace: {secondary: {deltaPercent: 3}}}]));
    assert.equal(model.barLabel(rows, 'remaining', {scopedCaps: true}), '5H 37% · 7D 61% · Fable 7% · +3%');
});
test('a scoped cap never displaces the general weekly lane or its pace', () => {
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        secondary: weekly,
        extraRateWindows: [{id: 'scoped', title: 'Fable only',
            window: {usedPercent: 93, windowMinutes: 10080}}]},
        pace: {secondary: {deltaPercent: -8}}}]));
    assert.equal(model.barLabel(rows, 'remaining', {scopedCaps: true}), '7D 61% · Fable 7% · -8%');
});
test('a provider whose only weekly data is scoped still shows a weekly lane, and no pace slot', () => {
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        extraRateWindows: [{id: 'scoped', title: 'Fable only',
            window: {usedPercent: 93, windowMinutes: 10080}}]}}]));
    // The cadence is derived from the only lane reporting it, so the quota stays visible
    // even with scoped caps switched off, and it is not also repeated by name.
    for (const scopedCaps of [true, false]) {
        const label = model.barLabel(rows, 'remaining', {scopedCaps});
        assert.equal(label, '7D 7%');
        assert.ok(!label.includes('—'));
    }
});
test('a reserve pool is excluded by being less constrained, not by its name', () => {
    const reserve = lanes({secondary: weekly,
        extraRateWindows: [{id: 'codex-weekly-scoped-gpt-reserve', title: 'gpt-reserve only',
            window: {usedPercent: 3, windowMinutes: 10080}}]}, {secondary: {deltaPercent: 3}});
    assert.equal(model.barLabel(reserve, 'remaining', {scopedCaps: true}), '7D 61% · +3%');
    // Same lane, same name, but now the tighter of the two: the rule is the number.
    const drained = lanes({secondary: weekly,
        extraRateWindows: [{id: 'codex-weekly-scoped-gpt-reserve', title: 'gpt-reserve only',
            window: {usedPercent: 98, windowMinutes: 10080}}]}, {secondary: {deltaPercent: 3}});
    assert.equal(model.barLabel(drained, 'remaining', {scopedCaps: true}), '7D 61% · gpt-reserve 2% · +3%');
});

test('a scoped cap that merely restates its general lane stays out of the bar', () => {
    const mirrored = model.rows(JSON.stringify([{provider: 'antigravity', usage: {
        primary: {usedPercent: 100, windowMinutes: 300, resetsAt: '2030-01-01T00:00:00Z'},
        secondary: {usedPercent: 4, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'},
        extraRateWindows: [
            {id: 'g5', title: 'Gemini 5-hour', window: {usedPercent: 100, windowMinutes: 300}},
            {id: 'gw', title: 'Gemini weekly', window: {usedPercent: 4, windowMinutes: 10080}},
            {id: 'cw', title: 'Claude/GPT weekly', window: {usedPercent: 0, windowMinutes: 10080}}]}}]));
    assert.equal(model.barLabel(mirrored, 'remaining', {scopedCaps: true}), '5H 0% · 7D 96%');
    // The popup still receives every lane the provider reported.
    assert.equal(mirrored[0].windows.length, 5);
});
test('a scoped cap tighter than its general lane still earns a bar segment', () => {
    const binding = model.rows(JSON.stringify([{provider: 'claude', usage: {
        secondary: {usedPercent: 71, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'},
        extraRateWindows: [{id: 'f', title: 'Fable only', window: {usedPercent: 99, windowMinutes: 10080}}]}}]));
    assert.equal(model.barLabel(binding, 'remaining', {scopedCaps: true}), '7D 29% · Fable 1%');
});

const perModelOnly = {provider: 'antigravity', usage: {
    primary: {usedPercent: 7, windowMinutes: 300, resetsAt: '2030-01-01T00:00:00Z'},
    secondary: {usedPercent: 0, windowMinutes: 300, resetsAt: '2030-01-01T00:00:00Z'},
    extraRateWindows: [
        {id: 'gw', title: 'Gemini weekly', window: {usedPercent: 6, windowMinutes: 10080}},
        {id: 'cw', title: 'Claude/GPT weekly', window: {usedPercent: 0, windowMinutes: 10080}}]}};

test('a provider with no general window of a cadence derives one from its tightest per-model lane', () => {
    const rows = model.rows(JSON.stringify([perModelOnly]));
    // 94% beats 100%: the lane that actually binds, matching Core's mostConstrained.
    assert.equal(model.barLabel(rows, 'remaining', {scopedCaps: true}), '5H 93% · 7D 94%');
    assert.equal(model.barLabel(rows, 'remaining', {scopedCaps: false}), '5H 93% · 7D 94%');
});
test('scoped caps are opt-in and never duplicate the lane they were derived into', () => {
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        secondary: {usedPercent: 80, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'},
        extraRateWindows: [{id: 'f', title: 'Fable only', window: {usedPercent: 100, windowMinutes: 10080}}]}}]));
    assert.equal(model.barLabel(rows, 'remaining', {scopedCaps: false}), '7D 20%');
    assert.equal(model.barLabel(rows, 'remaining', {scopedCaps: true}), '7D 20% · Fable 0%');
    // Default with no options behaves as off.
    assert.equal(model.barLabel(rows, 'remaining'), '7D 20%');
});
test('the pace preference controls the bar pace as it controls the native cards', () => {
    const rows = model.rows(JSON.stringify([{provider: 'codex',
        usage: {secondary: weekly}, pace: {secondary: {deltaPercent: 14}}}]));
    assert.equal(model.barLabel(rows, 'remaining', {pace: true}), '7D 61% · +14%');
    assert.equal(model.barLabel(rows, 'remaining', {pace: false}), '7D 61%');
});

test('a window the provider cannot measure never becomes a quota', () => {
    // Zed reports an overdue invoice and Antigravity a reset-only pool this way.
    const unmeasured = model.rows(JSON.stringify([{provider: 'zed', usage: {
        secondary: {usedPercent: 10, windowMinutes: 10080},
        extraRateWindows: [{id: 'b', title: 'Billing', usageKnown: false,
            window: {usedPercent: 100, windowMinutes: 10080}}]}}]));
    assert.equal(model.barLabel(unmeasured, 'remaining', {scopedCaps: true}), '7D 90%');
    assert.equal(unmeasured[0].windows.length, 1, 'the unmeasured lane must not reach the popup either');
});
test('a synthetic placeholder session is not a full session', () => {
    // Claude emits this when its web API reports no active five-hour window.
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        primary: {usedPercent: 0, windowMinutes: 300, isSyntheticPlaceholder: true},
        secondary: {usedPercent: 39, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'}},
        pace: {secondary: {deltaPercent: 14}}}]));
    assert.equal(model.barLabel(rows, 'remaining'), '7D 61% · +14%');
});
test('a quota on its own cadence survives a scoped allowance beside it', () => {
    // Cursor bills monthly and reports a separate weekly Grok Bot allowance.
    const rows = model.rows(JSON.stringify([{provider: 'cursor', usage: {
        primary: {usedPercent: 25, windowMinutes: 43200},
        extraRateWindows: [{id: 'g', title: 'Grok Bot', window: {usedPercent: 50, windowMinutes: 10080}}]}}]));
    const label = model.barLabel(rows, 'remaining', {scopedCaps: true});
    assert.ok(label.includes('30D 75%'), `monthly quota missing from ${label}`);
});
test('a cadence-less scoped lane must out-bind the provider before it earns space', () => {
    // Antigravity's per-model quotas report no windowMinutes at all.
    const entry = extras => ({provider: 'antigravity', usage: {
        primary: {usedPercent: 10, windowMinutes: 300}, secondary: {usedPercent: 20, windowMinutes: 10080},
        extraRateWindows: extras}});
    const idle = model.rows(JSON.stringify([entry([
        {id: 'a', title: 'Gemini 2.5 Flash', window: {usedPercent: 0, windowMinutes: null}}])]));
    assert.equal(model.barLabel(idle, 'remaining', {scopedCaps: true}), '5H 90% · 7D 80%');
    const binding = model.rows(JSON.stringify([entry([
        {id: 'b', title: 'Gemini 2.5 Pro', window: {usedPercent: 95, windowMinutes: null}}])]));
    assert.equal(model.barLabel(binding, 'remaining', {scopedCaps: true}), '5H 90% · 7D 80% · Gemini 2.5 Pro 5%');
});
test('a billing cycle that is not whole days is still named in days', () => {
    const rows = model.rows(JSON.stringify([{provider: 'cursor',
        usage: {primary: {usedPercent: 25, windowMinutes: 41040}}}]));
    assert.equal(model.barLabel(rows, 'remaining'), '29D 75%');
});

test('a cadence resolves to the pool that binds hardest, not the one listed first', () => {
    // Antigravity reports one pool per model family at the same cadence.
    const rows = model.rows(JSON.stringify([{provider: 'antigravity', usage: {
        primary: {usedPercent: 7, windowMinutes: 300}, secondary: {usedPercent: 100, windowMinutes: 300}}}]));
    assert.equal(model.barLabel(rows, 'remaining'), '5H 0%');
});
test("a provider whose whole quota arrives as an extra window still gets a lane", () => {
    // Kimi delivers a subscription-only account's pool through extraRateWindows.
    const rows = model.rows(JSON.stringify([{provider: 'kimi', usage: {
        extraRateWindows: [{id: 'kimi-monthly', title: 'Total usage',
            window: {usedPercent: 80, windowMinutes: 43200}}]}}]));
    assert.equal(model.barLabel(rows, 'remaining'), '30D 20%');
    assert.equal(model.barLabel(rows, 'remaining', {scopedCaps: false}), '30D 20%');
});
test('windows sharing a duration are distinct quotas, and the provider lists its own first', () => {
    // Cursor bills total, Auto/Composer and API usage over one cycle.
    const rows = model.rows(JSON.stringify([{provider: 'cursor', usage: {
        primary: {usedPercent: 25, windowMinutes: 43200},
        secondary: {usedPercent: 90, windowMinutes: 43200},
        tertiary: {usedPercent: 10, windowMinutes: 43200}}}]));
    assert.equal(model.barLabel(rows, 'remaining'), '30D 75%');
});
test('two cadence-less lanes keep a stable order rather than an engine-defined one', () => {
    const rows = model.rows(JSON.stringify([{provider: 'custom', usage: {
        primary: {usedPercent: 10}, secondary: {usedPercent: 20}}}]));
    const first = model.barLabel(rows, 'remaining');
    for (let i = 0; i < 20; i += 1) assert.equal(model.barLabel(rows, 'remaining'), first);
    assert.equal(first, 'Session 90% · Weekly 80%');
});

test('the tray summary and the bar agree about which lane binds', () => {
    const rows = model.rows(JSON.stringify([{provider: 'antigravity', usage: {
        primary: {usedPercent: 7, windowMinutes: 300}, secondary: {usedPercent: 100, windowMinutes: 300}}}]));
    assert.equal(model.summary(rows, 'remaining'), 'antigravity 0%');
    assert.ok(model.barLabel(rows, 'remaining').includes('0%'));
});
test('an unmeasurable window reaches neither the notifications nor the copied summary', () => {
    const rows = model.rows(JSON.stringify([{provider: 'zed', usage: {
        secondary: {usedPercent: 10, windowMinutes: 10080},
        extraRateWindows: [{id: 'b', title: 'Billing', usageKnown: false,
            window: {usedPercent: 100, windowMinutes: 10080}}]}}]));
    assert.equal(rows[0].windows.length, 1);
    assert.ok(!JSON.stringify(rows).includes('Billing'));
});

test('a sub-hour cadence is named in minutes rather than rounded away', () => {
    const rows = model.rows(JSON.stringify([{provider: 'custom',
        usage: {primary: {usedPercent: 40, windowMinutes: 45}}}]));
    assert.equal(model.barLabel(rows, 'remaining'), '45M 60%');
});

test('a cadence the provider summarises resolves across that summary set', () => {
    // Antigravity names one family per cadence as the positional window and marks every
    // family in the extras with a quota-summary id, so the tighter family sits there.
    const rows = model.rows(JSON.stringify([{provider: 'antigravity', usage: {
        primary: {usedPercent: 90, windowMinutes: 10080},
        secondary: {usedPercent: 60, windowMinutes: 300},
        extraRateWindows: [
            {id: 'antigravity-quota-summary-gemini-5h', title: 'Gemini 5-hour',
                window: {usedPercent: 80, windowMinutes: 300}},
            {id: 'antigravity-quota-summary-gemini-weekly', title: 'Gemini weekly',
                window: {usedPercent: 90, windowMinutes: 10080}},
            {id: 'antigravity-quota-summary-3p-5h', title: 'Claude/GPT 5-hour',
                window: {usedPercent: 60, windowMinutes: 300}},
            {id: 'antigravity-quota-summary-3p-weekly', title: 'Claude/GPT weekly',
                window: {usedPercent: 50, windowMinutes: 10080}}]}}]));
    assert.equal(model.barLabel(rows, 'remaining'), '5H 20% · 7D 10%');
});
test('a general quota that merely coincides with a scoped cap is not replaced by one', () => {
    // Claude can report several independently valued scoped caps, and one may land on the
    // same rounded percentage as the general weekly window. That is a coincidence, not a
    // statement that the caps summarise the cadence.
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        secondary: {usedPercent: 71, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'},
        extraRateWindows: [
            {id: 'claude-weekly-scoped-opus', title: 'Opus only',
                window: {usedPercent: 71, windowMinutes: 10080}},
            {id: 'claude-weekly-scoped-nova', title: 'Nova only',
                window: {usedPercent: 93, windowMinutes: 10080}}]},
        pace: {secondary: {deltaPercent: -8}}}]));
    assert.equal(model.barLabel(rows, 'remaining'), '7D 29% · -8%');
    assert.equal(model.barLabel(rows, 'remaining', {scopedCaps: true}), '7D 29% · Nova 7% · -8%');
    assert.equal(model.summary(rows, 'remaining'), 'CL 29%');
});
test("a general lane absent from the extras is not replaced by a cap scoped beneath it", () => {
    // Claude's weekly window has no twin among its per-model caps, so the cap must not take
    // over the lane the way an Antigravity family representative does.
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        primary: {usedPercent: 2, windowMinutes: 300},
        secondary: {usedPercent: 71, windowMinutes: 10080},
        extraRateWindows: [{id: 'f', title: 'Fable only',
            window: {usedPercent: 93, windowMinutes: 10080}}]}}]));
    assert.equal(model.barLabel(rows, 'remaining', {scopedCaps: true}), '5H 98% · 7D 29% · Fable 7%');
});
test('a window already shown as a cadence headline is not repeated as a scoped cap', () => {
    const rows = model.rows(JSON.stringify([{provider: 'kimi', usage: {
        extraRateWindows: [{id: 'kimi-monthly', title: 'Total usage',
            window: {usedPercent: 80, windowMinutes: 43200}}]}}]));
    assert.equal(model.barLabel(rows, 'remaining', {scopedCaps: true}), '30D 20%');
});
test('the tray summary names the lane the bar leads with, not the tightest subquota', () => {
    // Cursor bills its total, Auto/Composer and API usage over one cycle.
    const rows = model.rows(JSON.stringify([{provider: 'cursor', usage: {
        primary: {usedPercent: 25, windowMinutes: 43200},
        secondary: {usedPercent: 90, windowMinutes: 43200},
        tertiary: {usedPercent: 10, windowMinutes: 43200}}}]));
    assert.equal(model.barLabel(rows, 'remaining'), '30D 75%');
    assert.equal(model.summary(rows, 'remaining'), 'cursor 75%');
});

test('the lane bound keeps the tightest pools, so a summary set cannot lose an exhausted one', () => {
    // Antigravity's parser accepts an unbounded bucket array; an exhausted pool listed last
    // must not be truncated away before the cadence resolves across the set.
    const buckets = Array.from({length: 9}, (_, index) => ({
        id: 'antigravity-quota-summary-m' + index, title: 'M' + index,
        window: {usedPercent: index === 8 ? 100 : 10, windowMinutes: 300}}));
    const rows = model.rows(JSON.stringify([{provider: 'antigravity', usage: {
        primary: {usedPercent: 100, windowMinutes: 300}, extraRateWindows: buckets}}]));
    assert.equal(model.barLabel(rows, 'remaining'), '5H 0%');
    assert.equal(model.summary(rows, 'remaining'), 'antigravity 0%');
    assert.equal(rows[0].windows.filter(window => window.scoped).length, 8, 'bound must still hold');
});

test('every configured provider reaches the bar rather than collapsing into a count', () => {
    const rows = model.rows(JSON.stringify(['codex', 'claude', 'gemini', 'copilot', 'cursor'].map(provider => (
        {provider, usage: {secondary: weekly}}))));
    const label = model.barLabel(rows, 'remaining');
    for (const tag of ['CX', 'CL', 'gemini', 'copilot', 'cursor']) assert.ok(label.includes(tag + ' 7D 61%'), tag);
    assert.ok(!/\+\d/.test(label), 'no overflow count should remain');
});
