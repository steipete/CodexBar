import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const model = vm.createContext({});
vm.runInContext(fs.readFileSync(new URL('../Linux/Shared/Usage.js', import.meta.url), 'utf8'), model);
test('bar entries preserve compact summary quotas, order, privacy and the two-entry limit', () => {
    const rows = model.rows(JSON.stringify([
        {provider: 'codex', usage: {primary: {usedPercent: 10}, identity: {accountEmail: 'private@example.com'}}},
        {provider: 'acme', usage: {primary: {usedPercent: 20}}},
        {provider: 'claude', usage: {primary: {usedPercent: 30}}}]), true);
    assert.deepEqual(JSON.parse(JSON.stringify(model.barSegments(rows, 'remaining'))), [
        {provider: 'codex', tag: 'CX', text: '90%'},
        {provider: 'acme', tag: 'acme', text: '80%'}]);
    assert.equal(model.summary(rows, 'remaining'), 'CX 90%  ·  acme 80%  +1');
    assert.deepEqual([...model.barSegments(rows, 'used').map(segment => segment.text)], ['10%', '20%']);
    assert.equal(model.summary(rows, 'used'), 'CX 10%  ·  acme 20%  +1');
    assert.equal(rows.length, 3, 'hidden providers stay available to the popup and notifications');
});
test('bar entries retain unavailable quotas and handle empty or single-provider snapshots', () => {
    assert.equal(model.barSegments([]).length, 0);
    assert.equal(model.summary([]), '');
    const rows = model.rows(JSON.stringify([{provider: 'claude', error: {message: 'private error'}}]));
    assert.deepEqual(JSON.parse(JSON.stringify(model.barSegments(rows))), [
        {provider: 'claude', tag: 'CL', text: '—'}]);
    assert.equal(model.summary(rows), 'CL —');
});
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
test('durationless quota uses provider labels without inventing a weekly cadence', () => {
    const input = {provider: 'v0', rateWindowLabels: {secondary: ' Rate limit '},
        usage: {secondary: {usedPercent: 20}}};
    const row = model.rows(JSON.stringify(input))[0].windows[0];
    assert.equal(row.key, 'secondary');
    assert.equal(row.label, 'Rate limit');
    assert.equal(row.remaining, 80);
    input.usage.secondary.windowMinutes = 300;
    assert.equal(model.rows(JSON.stringify(input))[0].windows[0].label, '5 hour');
});
test('provider labels preserve fallback and IPC identity privacy', () => {
    for (const label of [null, '', '  ', 42, {}, []]) {
        const input = {provider: 'v0', rateWindowLabels: {secondary: label},
            usage: {secondary: {usedPercent: 20}}};
        assert.equal(model.rows(JSON.stringify(input))[0].windows[0].label, 'Weekly');
    }
    const input = {provider: 'v0', rateWindowLabels: {secondary: 'private@example.com rate limit'},
        usage: {secondary: {usedPercent: 20}}};
    assert.equal(model.rows(JSON.stringify(input), true)[0].windows[0].label, '[hidden email] rate limit');
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

const scopedWeekly = {usedPercent: 93, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'};

test('a provider-scoped cap reaches the model instead of being dropped', () => {
    const row = model.rows(JSON.stringify([{provider: 'claude', usage: {
        primary: {usedPercent: 21, windowMinutes: 300},
        secondary: {usedPercent: 71, windowMinutes: 10080},
        extraRateWindows: [{id: 'claude-weekly-scoped-fable', title: 'Fable only',
            window: scopedWeekly}]}}]))[0];
    assert.deepEqual([...row.windows.map(window => window.key)],
        ['primary', 'secondary', 'extra:claude-weekly-scoped-fable']);
    assert.equal(row.windows[2].label, 'Fable only');
    assert.equal(row.windows[2].remaining, 7);
    assert.equal(row.error, '');
});
test('extras follow the standard lanes so a cadence lookup still finds the general window', () => {
    const row = model.rows(JSON.stringify([{provider: 'claude', usage: {
        secondary: {usedPercent: 71, windowMinutes: 10080},
        extraRateWindows: [{id: 'scoped', title: 'Fable only', window: scopedWeekly}]}}]))[0];
    assert.equal(row.windows[0].key, 'secondary');
});
test('a window the provider cannot measure never becomes a quota', () => {
    // Zed reports an overdue invoice this way; Antigravity a reset-only pool.
    const row = model.rows(JSON.stringify([{provider: 'zed', usage: {
        secondary: {usedPercent: 10, windowMinutes: 10080},
        extraRateWindows: [{id: 'b', title: 'Billing', usageKnown: false,
            window: {usedPercent: 100, windowMinutes: 10080}}]}}]))[0];
    assert.equal(row.windows.length, 1);
    assert.ok(!JSON.stringify(row).includes('Billing'));
});
test('a synthetic placeholder session is not a measured window', () => {
    const row = model.rows(JSON.stringify([{provider: 'claude', usage: {
        primary: {usedPercent: 0, windowMinutes: 300, isSyntheticPlaceholder: true},
        secondary: {usedPercent: 39, windowMinutes: 10080}}}]))[0];
    assert.deepEqual([...row.windows.map(window => window.key)], ['secondary']);
});
test('scoped titles are redacted for identity even when identity display is enabled', () => {
    const input = JSON.stringify([{provider: 'claude', usage: {extraRateWindows: [
        {id: 'scoped', title: 'Fable (private@example.com)', window: scopedWeekly}]}}]);
    assert.equal(model.rows(input)[0].windows[0].label, 'Fable [hidden email]');
    assert.equal(model.rows(input, true)[0].windows[0].label, 'Fable [hidden email]');
});
test('extras are bounded, counting lanes that render rather than entries received', () => {
    const junk = Array.from({length: 8}, (_, index) => (
        {id: 'junk-' + index, title: 'Junk', window: {usedPercent: null}}));
    const row = model.rows(JSON.stringify([{provider: 'claude', usage: {extraRateWindows: [...junk,
        {id: 'real', title: 'Fable only', window: scopedWeekly}]}}]))[0];
    assert.deepEqual([...row.windows.map(window => window.key)], ['extra:real']);
    const many = Array.from({length: 10}, (_, index) => (
        {id: 'e' + index, title: 'Lane ' + index, window: {usedPercent: index, windowMinutes: 60}}));
    assert.equal(model.rows(JSON.stringify([{provider: 'claude',
        usage: {extraRateWindows: many}}]))[0].windows.length, 8);
});
test('existing fractional day labels are preserved', () => {
    const row = model.rows(JSON.stringify([{provider: 'cursor',
        usage: {primary: {usedPercent: 25, windowMinutes: 41040}}}]))[0];
    assert.equal(row.windows[0].label, '28.5 day');
});

test('extras without stable identifiers cannot borrow another notification identity', () => {
    const invalid = [undefined, null, false, 0, '', '  ', {}, []].map(id => ({id, title: 'Invalid',
        window: scopedWeekly}));
    const windows = model.rows(JSON.stringify([{provider: 'claude', usage: {extraRateWindows: [
        ...invalid, {id: '0', title: 'Measured cap', window: scopedWeekly}
    ]}}]))[0].windows;
    assert.deepEqual([...windows.map(window => window.key)], ['extra:0']);
});

const pool = (usedPercent, windowMinutes, resetsAt) => ({usedPercent, windowMinutes, resetsAt});
const quotaSummary = (id, title, window) => ({id: 'antigravity-quota-summary-' + id, title, usageKnown: true, window});

test('a pool reported as a quota summary is listed once, in its representative slot', () => {
    const geminiWeekly = pool(7, 10080, '2026-09-23T00:00:00Z');
    const claudeSession = pool(0, 300, '2026-09-21T01:00:00Z');
    const [row] = model.rows(JSON.stringify([{provider: 'antigravity', usage: {
        primary: geminiWeekly, secondary: claudeSession, extraRateWindows: [
            quotaSummary('gemini-5h', 'Gemini 5-hour', pool(3, 300, '2026-09-20T23:00:00Z')),
            quotaSummary('gemini-weekly', 'Gemini weekly', geminiWeekly),
            quotaSummary('claude-5h', 'Claude/GPT 5-hour', claudeSession),
            quotaSummary('claude-weekly', 'Claude/GPT weekly', pool(0, 10080, '2026-09-27T00:00:00Z'))]}}]));
    assert.deepEqual([...row.windows.map(window => window.key + ' ' + window.label + ' ' + window.remaining)], [
        'extra:antigravity-quota-summary-gemini-weekly Gemini weekly 93',
        'extra:antigravity-quota-summary-claude-5h Claude/GPT 5-hour 100',
        'extra:antigravity-quota-summary-gemini-5h Gemini 5-hour 97',
        'extra:antigravity-quota-summary-claude-weekly Claude/GPT weekly 100']);
});

test('family representatives still lead, so the summary and tray report the binding pools', () => {
    const geminiWeekly = pool(95, 10080, '2026-09-23T00:00:00Z');
    const claudeSession = pool(100, 300, '2026-09-21T01:00:00Z');
    const rows = model.rows(JSON.stringify([{provider: 'antigravity', usage: {
        primary: geminiWeekly, secondary: claudeSession, extraRateWindows: [
            quotaSummary('gemini-5h', 'Gemini 5-hour', pool(0, 300, '2026-09-20T23:00:00Z')),
            quotaSummary('gemini-weekly', 'Gemini weekly', geminiWeekly),
            quotaSummary('claude-5h', 'Claude/GPT 5-hour', claudeSession)]}}]));
    assert.equal(model.summary(rows, 'remaining'), 'antigravity 5%');
    assert.deepEqual([...rows[0].windows.slice(0, 2).map(window => window.label + ' ' + window.remaining)],
        ['Gemini weekly 5', 'Claude/GPT 5-hour 0']);
});

test('a representative listed beyond the extra limit is never hidden', () => {
    const exhausted = pool(100, 300, '2026-09-21T01:00:00Z');
    const idle = Array.from({length: 8}, (_, index) =>
        quotaSummary('idle-' + index, 'Idle ' + index, pool(5, 300, '2026-09-21T0' + index + ':30:00Z')));
    const [row] = model.rows(JSON.stringify([{provider: 'antigravity', usage: {
        primary: exhausted, extraRateWindows: [...idle, quotaSummary('gemini-5h', 'Gemini 5-hour', exhausted)]}}]));
    assert.equal(row.windows[0].label + ' ' + row.windows[0].remaining, 'Gemini 5-hour 0');
    assert.equal(row.windows.length, 9);
});

test('representative matching is confined to Antigravity quota-summary buckets', () => {
    const window = pool(50, 300, '2030-01-01T00:00:00Z');
    for (const [provider, id] of [
        ['claude', 'antigravity-quota-summary-gemini'],
        ['antigravity', 'custom-quota-summary-gemini'],
        ['antigravity', 'legacy-gemini']
    ]) {
        const [row] = model.rows(JSON.stringify([{provider, usage: {primary: window, extraRateWindows: [
            {id, title: 'Gemini Session', window}]}}]));
        assert.deepEqual([...row.windows.map(item => item.key)], ['primary', 'extra:' + id]);
    }
});

test('an unrelated matching extra cannot take the quota-summary representative slot', () => {
    const window = pool(50, 300, '2030-01-01T00:00:00Z');
    const [row] = model.rows(JSON.stringify([{provider: 'antigravity', usage: {primary: window, extraRateWindows: [
        {id: 'legacy-gemini', title: 'Gemini Legacy', window},
        quotaSummary('gemini-session', 'Gemini Session', window)]}}]));
    assert.deepEqual([...row.windows.map(item => item.label)], ['Gemini Session', 'Gemini Legacy']);
});

test('representative family titles remain redacted and distinct resets remain separate', () => {
    const window = pool(50, 300, '2030-01-01T00:00:00Z');
    const [row] = model.rows(JSON.stringify([{provider: 'antigravity', usage: {primary: window, extraRateWindows: [
        quotaSummary('gemini-other', 'Gemini Other', {...window, resetsAt: '2030-01-02T00:00:00Z'}),
        quotaSummary('gemini-session', 'Gemini private@example.com Session', window)]}}]), true);
    assert.deepEqual([...row.windows.map(item => item.label)], ['Gemini [hidden email] Session', 'Gemini Other']);
    assert.equal(row.windows.length, 2);
});

test('identical same-family windows use Core title ordering for the representative', () => {
    const window = pool(50, 300, '2030-01-01T00:00:00Z');
    const [row] = model.rows(JSON.stringify([{provider: 'antigravity', usage: {primary: window, extraRateWindows: [
        quotaSummary('gemini-zebra', 'Gemini Zebra', window),
        quotaSummary('gemini-amber', 'gemini amber', window)]}}]));
    assert.deepEqual([...row.windows.map(item => item.key)], [
        'extra:antigravity-quota-summary-gemini-amber', 'extra:antigravity-quota-summary-gemini-zebra']);
});

const lanes = (windows, pace) => model.rows(JSON.stringify([{provider: 'codex', usage: windows, pace}]));

const perModelOnly = {provider: 'antigravity', usage: {
    primary: {usedPercent: 7, windowMinutes: 300, resetsAt: '2030-01-01T00:00:00Z'},
    secondary: {usedPercent: 0, windowMinutes: 300, resetsAt: '2030-01-01T00:00:00Z'},
    extraRateWindows: [
        {id: 'gw', title: 'Gemini weekly', window: {usedPercent: 6, windowMinutes: 10080}},
        {id: 'cw', title: 'Claude/GPT weekly', window: {usedPercent: 0, windowMinutes: 10080}}]}};

const scopedEntry = {provider: 'claude', usage: {
    primary: {usedPercent: 21, windowMinutes: 300, resetsAt: '2026-09-18T18:00:00Z'},
    secondary: {usedPercent: 71, windowMinutes: 10080, resetsAt: '2026-09-21T09:00:00Z'},
    extraRateWindows: [{id: 'claude-weekly-scoped-fable', title: 'Fable only',
        window: {usedPercent: 93, windowMinutes: 10080, resetsAt: '2026-09-21T09:00:00Z'}}]}};

const session = {usedPercent: 63, windowMinutes: 300, resetsAt: '2030-01-01T00:00:00Z'};

const weekly = {usedPercent: 39, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'};

// Detail is opt-in, so these helpers ask for it and render the label the adapters join.
const label = (shown, total) => shown.map(entry => (total > 1 ? entry.tag + ' ' : '') + entry.text).join('  ·  ') +
    (total > shown.length ? '  +' + (total - shown.length) : '');
const compactLabel = (rows, mode, options) => label(model.barSegments(rows, mode, options), rows.length);
const detailedSegments = (rows, mode, options) => model.barSegments(rows, mode, {detail: true, ...(options || {})});
const detailedLabel = (rows, mode, options) => label(detailedSegments(rows, mode, options), rows.length);

test('bar shows session quota, weekly quota, then the weekly pace', () => {
    const rows = lanes({primary: session, secondary: weekly}, {secondary: {deltaPercent: 14, summary: '14% in deficit'}});
    assert.equal(detailedLabel(rows, 'remaining'), '5H 37% · 7D 61% · +14%');
    assert.equal(detailedLabel(rows, 'used'), '5H 63% · 7D 39% · +14%');
    assert.equal(rows[0].windows[1].minutes, 10080);
});

test('a weekly reserve keeps its negative sign and an exact pace reads as zero', () => {
    assert.equal(detailedLabel(lanes({primary: session, secondary: weekly},
        {secondary: {deltaPercent: -8}}), 'remaining'), '5H 37% · 7D 61% · -8%');
    assert.equal(detailedLabel(lanes({secondary: weekly}, {secondary: {deltaPercent: 0.4}}), 'remaining'), '7D 61% · 0%');
});

test('pace always describes the weekly window, never the most constrained lane', () => {
    const rows = lanes({primary: session, secondary: weekly},
        {primary: {deltaPercent: 31}, secondary: {deltaPercent: -8}});
    assert.equal(detailedLabel(rows, 'remaining'), '5H 37% · 7D 61% · -8%');
});

test('a provider without a session window omits that segment and its separator', () => {
    const label = detailedLabel(lanes({secondary: weekly}, {secondary: {deltaPercent: 14}}), 'remaining');
    assert.equal(label, '7D 61% · +14%');
    assert.ok(!label.includes('5H'));
    assert.ok(!label.startsWith(' ·'));
});

test('a provider without a weekly window shows the session lane alone', () => {
    const label = detailedLabel(lanes({primary: session}, {primary: {deltaPercent: 14}}), 'remaining');
    assert.equal(label, '5H 37%');
    assert.ok(!label.includes('·'));
    assert.ok(!label.includes('—'));
});

test('an unavailable weekly pace is omitted entirely rather than shown as a dash', () => {
    assert.equal(detailedLabel(lanes({secondary: weekly}, null), 'remaining'), '7D 61%');
    for (const value of [{}, {deltaPercent: null}, {deltaPercent: 'nope'}, {deltaPercent: Infinity}])
        assert.equal(detailedLabel(lanes({secondary: weekly}, {secondary: value}), 'remaining'), '7D 61%');
});

test('missing quota values never produce empty segments or stray separators', () => {
    assert.equal(detailedLabel(lanes({primary: {usedPercent: null, windowMinutes: 300}, secondary: weekly},
        {secondary: {deltaPercent: 14}}), 'remaining'), '7D 61% · +14%');
    assert.equal(detailedLabel(lanes({}, null), 'remaining'), '—');
    assert.equal(detailedLabel([], 'remaining'), '');
    for (const label of [detailedLabel(lanes({secondary: weekly}, null), 'remaining'), detailedLabel(lanes({}, null), 'remaining')])
        assert.ok(!/(^|\s)·\s*·|·\s*$|^\s*·/.test(label));
});

test('an unreported cadence keeps its own lane rather than borrowing weekly pace', () => {
    const monthly = {usedPercent: 25, windowMinutes: 43200, resetsAt: '2030-01-02T00:00:00Z'};
    assert.equal(detailedLabel(lanes({primary: monthly}, {primary: {deltaPercent: 14}}), 'remaining'), '30D 75%');
    assert.equal(detailedLabel(lanes({primary: {usedPercent: 25}}, null), 'remaining'), 'Session 75%');
});

test('a failed provider row keeps the healthy provider labelled and never fabricates pace', () => {
    const rows = model.rows(JSON.stringify([
        {provider: 'codex', usage: {secondary: weekly}, pace: {secondary: {deltaPercent: 14}}},
        {provider: 'claude', error: {message: 'secret upstream response'}}]));
    assert.equal(detailedLabel(rows, 'remaining'), 'CX 7D 61% · +14%  ·  CL —');
    assert.ok(!JSON.stringify(rows).includes('secret'));
});

test('extra rate windows are appended after the standard lanes so the real weekly lane wins a cadence lookup', () => {
    const row = model.rows(JSON.stringify([scopedEntry]))[0];
    assert.deepEqual([...row.windows.map(window => window.key)],
        ['primary', 'secondary', 'extra:claude-weekly-scoped-fable']);
    assert.deepEqual({...row.windows[2]},
        {key: 'extra:claude-weekly-scoped-fable', label: 'Fable only', minutes: 10080, remaining: 7,
            resetsAt: '2026-09-21T09:00:00Z', pace: '', paceDelta: null, scoped: true});
    assert.equal(row.error, '');
});

test('an extra rate window with an unusable quota is skipped', () => {
    const entry = {provider: 'claude', usage: {extraRateWindows: [
        {id: 'bad', title: 'Broken', window: {usedPercent: '93', windowMinutes: 10080}},
        {id: 'good', title: 'Fable only', window: {usedPercent: 93, windowMinutes: 10080}}]}};
    const row = model.rows(JSON.stringify([entry]))[0];
    assert.deepEqual([...row.windows.map(window => window.key)], ['extra:good']);
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
    assert.deepEqual([...row.windows.map(window => window.key)], ['extra:good']);
    assert.equal(row.error, '');
});

test('the extra-window cap counts displayed lanes, not skipped ones', () => {
    const unusable = Array.from({length: 8}, (_, index) => (
        {id: 'junk-' + index, title: 'Junk', window: {usedPercent: null}}));
    const entry = {provider: 'claude', usage: {extraRateWindows: [...unusable,
        {id: 'claude-weekly-scoped-fable', title: 'Fable only', window: {usedPercent: 93, windowMinutes: 10080}}]}};
    assert.deepEqual([...model.rows(JSON.stringify([entry]))[0].windows.map(window => window.key)],
        ['extra:claude-weekly-scoped-fable']);
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
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: true}), '5H 37% · 7D 61% · Fable 7% · +3%');
});

test('a scoped cap never displaces the general weekly lane or its pace', () => {
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        secondary: weekly,
        extraRateWindows: [{id: 'scoped', title: 'Fable only',
            window: {usedPercent: 93, windowMinutes: 10080}}]},
        pace: {secondary: {deltaPercent: -8}}}]));
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: true}), '7D 61% · Fable 7% · -8%');
});

test('a provider whose only weekly data is scoped still shows a weekly lane, and no pace slot', () => {
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        extraRateWindows: [{id: 'scoped', title: 'Fable only',
            window: {usedPercent: 93, windowMinutes: 10080}}]}}]));
    // The cadence is derived from the only lane reporting it, so the quota stays visible
    // even with scoped caps switched off, and it is not also repeated by name.
    for (const scopedCaps of [true, false]) {
        const label = detailedLabel(rows, 'remaining', {scopedCaps});
        assert.equal(label, '7D 7%');
        assert.ok(!label.includes('—'));
    }
});

test('a reserve pool is excluded by being less constrained, not by its name', () => {
    const pool = used => model.rows(JSON.stringify([{provider: 'custom', usage: {secondary: weekly,
        extraRateWindows: [{id: 'reserve', title: 'Reserve only', window: {usedPercent: used, windowMinutes: 10080}}]},
        pace: {secondary: {deltaPercent: 3}}}]));
    assert.equal(detailedLabel(pool(3), 'remaining', {scopedCaps: true}), '7D 61% · +3%');
    // Same lane, same name, but now the tighter of the two: the rule is the number.
    assert.equal(detailedLabel(pool(98), 'remaining', {scopedCaps: true}), '7D 61% · Reserve 2% · +3%');
});

test("Codex's per-model limits show whether they are tighter, looser or level with the lane", () => {
    const spark = (fiveHour, week) => lanes({primary: session, secondary: weekly, extraRateWindows: [
        {id: 'codex-spark', title: 'Codex Spark 5-hour', window: {usedPercent: fiveHour, windowMinutes: 300}},
        {id: 'codex-spark-weekly', title: 'Codex Spark Weekly', window: {usedPercent: week, windowMinutes: 10080}}]});
    assert.equal(detailedLabel(spark(63, 39), 'remaining', {scopedCaps: true}),
        '5H 37% · 7D 61% · Codex Spark 5-hour 37% · Codex Spark Weekly 61%');
    assert.equal(detailedLabel(spark(10, 90), 'remaining', {scopedCaps: true}),
        '5H 37% · 7D 61% · Codex Spark 5-hour 90% · Codex Spark Weekly 10%');
    assert.equal(detailedLabel(spark(63, 39), 'remaining'), '5H 37% · 7D 61%');
    // The prefix belongs to Codex: another provider's look-alike id keeps the tightness rule.
    const other = model.rows(JSON.stringify([{provider: 'custom', usage: {secondary: weekly, extraRateWindows: [
        {id: 'codex-spark-weekly', title: 'Look-alike', window: {usedPercent: 39, windowMinutes: 10080}}]}}]));
    assert.equal(detailedLabel(other, 'remaining', {scopedCaps: true}), '7D 61%');
});

test('a scoped cap that merely restates its general lane stays out of the bar', () => {
    const mirrored = model.rows(JSON.stringify([{provider: 'antigravity', usage: {
        primary: {usedPercent: 100, windowMinutes: 300, resetsAt: '2030-01-01T00:00:00Z'},
        secondary: {usedPercent: 4, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'},
        extraRateWindows: [
            {id: 'g5', title: 'Gemini 5-hour', window: {usedPercent: 100, windowMinutes: 300}},
            {id: 'gw', title: 'Gemini weekly', window: {usedPercent: 4, windowMinutes: 10080}},
            {id: 'cw', title: 'Claude/GPT weekly', window: {usedPercent: 0, windowMinutes: 10080}}]}}]));
    assert.equal(detailedLabel(mirrored, 'remaining', {scopedCaps: true}), '5H 0% · 7D 96%');
    // The popup still receives every lane the provider reported.
    assert.equal(mirrored[0].windows.length, 5);
});

test('a scoped cap tighter than its general lane still earns a bar segment', () => {
    const binding = model.rows(JSON.stringify([{provider: 'claude', usage: {
        secondary: {usedPercent: 71, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'},
        extraRateWindows: [{id: 'f', title: 'Fable only', window: {usedPercent: 99, windowMinutes: 10080}}]}}]));
    assert.equal(detailedLabel(binding, 'remaining', {scopedCaps: true}), '7D 29% · Fable 1%');
});

test('a provider with no general window of a cadence derives one from its tightest per-model lane', () => {
    const rows = model.rows(JSON.stringify([perModelOnly]));
    // 94% beats 100%: the lane that actually binds, matching Core's mostConstrained.
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: true}), '5H 93% · 7D 94%');
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: false}), '5H 93% · 7D 94%');
});

test('scoped caps are opt-in and never duplicate the lane they were derived into', () => {
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        secondary: {usedPercent: 80, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'},
        extraRateWindows: [{id: 'f', title: 'Fable only', window: {usedPercent: 100, windowMinutes: 10080}}]}}]));
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: false}), '7D 20%');
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: true}), '7D 20% · Fable 0%');
    // Default with no options behaves as off.
    assert.equal(detailedLabel(rows, 'remaining'), '7D 20%');
});

test('the pace preference controls the bar pace as it controls the native cards', () => {
    const rows = model.rows(JSON.stringify([{provider: 'codex',
        usage: {secondary: weekly}, pace: {secondary: {deltaPercent: 14}}}]));
    assert.equal(detailedLabel(rows, 'remaining', {pace: true}), '7D 61% · +14%');
    assert.equal(detailedLabel(rows, 'remaining', {pace: false}), '7D 61%');
});

test('a synthetic placeholder session is not a full session', () => {
    // Claude emits this when its web API reports no active five-hour window.
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        primary: {usedPercent: 0, windowMinutes: 300, isSyntheticPlaceholder: true},
        secondary: {usedPercent: 39, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'}},
        pace: {secondary: {deltaPercent: 14}}}]));
    assert.equal(detailedLabel(rows, 'remaining'), '7D 61% · +14%');
});

test('a quota on its own cadence survives a scoped allowance beside it', () => {
    // Cursor bills monthly and reports a separate weekly Grok Bot allowance.
    const rows = model.rows(JSON.stringify([{provider: 'cursor', usage: {
        primary: {usedPercent: 25, windowMinutes: 43200},
        extraRateWindows: [{id: 'g', title: 'Grok Bot', window: {usedPercent: 50, windowMinutes: 10080}}]}}]));
    const label = detailedLabel(rows, 'remaining', {scopedCaps: true});
    assert.ok(label.includes('30D 75%'), `monthly quota missing from ${label}`);
});

test('a cadence-less scoped lane must out-bind the provider before it earns space', () => {
    // Antigravity's per-model quotas report no windowMinutes at all.
    const entry = extras => ({provider: 'antigravity', usage: {
        primary: {usedPercent: 10, windowMinutes: 300}, secondary: {usedPercent: 20, windowMinutes: 10080},
        extraRateWindows: extras}});
    const idle = model.rows(JSON.stringify([entry([
        {id: 'a', title: 'Gemini 2.5 Flash', window: {usedPercent: 0, windowMinutes: null}}])]));
    assert.equal(detailedLabel(idle, 'remaining', {scopedCaps: true}), '5H 90% · 7D 80%');
    const binding = model.rows(JSON.stringify([entry([
        {id: 'b', title: 'Gemini 2.5 Pro', window: {usedPercent: 95, windowMinutes: null}}])]));
    assert.equal(detailedLabel(binding, 'remaining', {scopedCaps: true}), '5H 90% · 7D 80% · Gemini 2.5 Pro 5%');
});

test('a billing cycle that is not whole days is still named in days', () => {
    const rows = model.rows(JSON.stringify([{provider: 'cursor',
        usage: {primary: {usedPercent: 25, windowMinutes: 41040}}}]));
    assert.equal(detailedLabel(rows, 'remaining'), '29D 75%');
});

test('a cadence resolves to the pool that binds hardest, not the one listed first', () => {
    // Antigravity reports one pool per model family at the same cadence.
    const rows = model.rows(JSON.stringify([{provider: 'antigravity', usage: {
        primary: {usedPercent: 7, windowMinutes: 300}, secondary: {usedPercent: 100, windowMinutes: 300}}}]));
    assert.equal(detailedLabel(rows, 'remaining'), '5H 0%');
});

test("a provider whose whole quota arrives as an extra window still gets a lane", () => {
    // Kimi delivers a subscription-only account's pool through extraRateWindows.
    const rows = model.rows(JSON.stringify([{provider: 'kimi', usage: {
        extraRateWindows: [{id: 'kimi-monthly', title: 'Total usage',
            window: {usedPercent: 80, windowMinutes: 43200}}]}}]));
    assert.equal(detailedLabel(rows, 'remaining'), '30D 20%');
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: false}), '30D 20%');
});

test('windows sharing a duration are distinct quotas, and the provider lists its own first', () => {
    // Cursor bills total, Auto/Composer and API usage over one cycle.
    const rows = model.rows(JSON.stringify([{provider: 'cursor', usage: {
        primary: {usedPercent: 25, windowMinutes: 43200},
        secondary: {usedPercent: 90, windowMinutes: 43200},
        tertiary: {usedPercent: 10, windowMinutes: 43200}}}]));
    assert.equal(detailedLabel(rows, 'remaining'), '30D 75%');
});

test('two cadence-less lanes keep a stable order rather than an engine-defined one', () => {
    const rows = model.rows(JSON.stringify([{provider: 'custom', usage: {
        primary: {usedPercent: 10}, secondary: {usedPercent: 20}}}]));
    const first = detailedLabel(rows, 'remaining');
    for (let i = 0; i < 20; i += 1) assert.equal(detailedLabel(rows, 'remaining'), first);
    assert.equal(first, 'Session 90% · Weekly 80%');
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
    assert.equal(detailedLabel(rows, 'remaining'), '45M 60%');
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
    assert.equal(detailedLabel(rows, 'remaining'), '5H 20% · 7D 10%');
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
    assert.equal(detailedLabel(rows, 'remaining'), '7D 29% · -8%');
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: true}), '7D 29% · Opus 29% · Nova 7% · -8%');
    assert.equal(model.summary(rows, 'remaining'), 'CL 29%');
});

test("Claude's per-model cap shows when asked for, even while it reads the same as the week", () => {
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        primary: session, secondary: {usedPercent: 3, windowMinutes: 10080, resetsAt: '2030-01-02T00:00:00Z'},
        extraRateWindows: [{id: 'claude-weekly-scoped-fable', title: 'Fable only',
            window: {usedPercent: 3, windowMinutes: 10080}}]}}]));
    assert.equal(compactLabel(rows, 'remaining'), '37%');
    assert.equal(compactLabel(rows, 'remaining', {scopedCaps: true}), '37% · Fable 97%');
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: true}), '5H 37% · 7D 97% · Fable 97%');
    // Only when the cap is the provider's sole weekly data is it already on show as the lane.
    const only = model.rows(JSON.stringify([{provider: 'claude', usage: {extraRateWindows: [
        {id: 'claude-weekly-scoped-fable', title: 'Fable only', window: {usedPercent: 3, windowMinutes: 10080}}]}}]));
    assert.equal(compactLabel(only, 'remaining', {scopedCaps: true}), '97%');
    assert.equal(detailedLabel(only, 'remaining', {scopedCaps: true}), '7D 97%');
});

test("a general lane absent from the extras is not replaced by a cap scoped beneath it", () => {
    // Claude's weekly window has no twin among its per-model caps, so the cap must not take
    // over the lane the way an Antigravity family representative does.
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        primary: {usedPercent: 2, windowMinutes: 300},
        secondary: {usedPercent: 71, windowMinutes: 10080},
        extraRateWindows: [{id: 'f', title: 'Fable only',
            window: {usedPercent: 93, windowMinutes: 10080}}]}}]));
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: true}), '5H 98% · 7D 29% · Fable 7%');
});

test('a window already shown as a cadence headline is not repeated as a scoped cap', () => {
    const rows = model.rows(JSON.stringify([{provider: 'kimi', usage: {
        extraRateWindows: [{id: 'kimi-monthly', title: 'Total usage',
            window: {usedPercent: 80, windowMinutes: 43200}}]}}]));
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: true}), '30D 20%');
});

test('the tray summary names the lane the bar leads with, not the tightest subquota', () => {
    // Cursor bills its total, Auto/Composer and API usage over one cycle.
    const rows = model.rows(JSON.stringify([{provider: 'cursor', usage: {
        primary: {usedPercent: 25, windowMinutes: 43200},
        secondary: {usedPercent: 90, windowMinutes: 43200},
        tertiary: {usedPercent: 10, windowMinutes: 43200}}}]));
    assert.equal(detailedLabel(rows, 'remaining'), '30D 75%');
    assert.equal(model.summary(rows, 'remaining'), 'cursor 75%');
});


test('every configured provider reaches the bar when the limit is lifted', () => {
    const rows = model.rows(JSON.stringify(['codex', 'claude', 'gemini', 'copilot', 'cursor'].map(provider => (
        {provider, usage: {secondary: weekly}}))));
    const text = detailedLabel(rows, 'remaining', {maxProviders: 0});
    for (const tag of ['CX', 'CL', 'gemini', 'copilot', 'cursor']) assert.ok(text.includes(tag + ' 7D 61%'), tag);
    assert.ok(!/\+\d/.test(text), 'nothing is hidden, so no count remains');
    assert.ok(/\+3$/.test(detailedLabel(rows, 'remaining')), 'the default limit counts the rest');
});

test('a provider whose only quota is cadence-less still reports it in the bar and the tooltip', () => {
    // Antigravity sends only a compact fallback when neither model family has a representative.
    const rows = model.rows(JSON.stringify([{provider: 'antigravity', usage: {extraRateWindows: [
        {id: 'antigravity-compact-fallback-model-a', title: 'Model A', usageKnown: true,
            window: {usedPercent: 64, windowMinutes: null}},
        {id: 'image-model', title: 'Image model', usageKnown: true, window: {usedPercent: 99, windowMinutes: null}}]}}]));
    assert.equal(detailedLabel(rows, 'remaining'), 'Model A 36%');
    assert.equal(model.summary(rows, 'remaining'), 'antigravity 36%');
    // Without the marker, per-model detail is not promoted to the provider's quota.
    const detailOnly = model.rows(JSON.stringify([{provider: 'antigravity', usage: {extraRateWindows: [
        {id: 'experimental', title: 'Experimental Model', usageKnown: true,
            window: {usedPercent: 64, windowMinutes: null}}]}}]));
    assert.equal(detailedLabel(detailOnly, 'remaining'), '—');
});


test('the bar limit is display only: it counts the providers it hides', () => {
    const rows = model.rows(JSON.stringify(['codex', 'claude', 'gemini', 'zai'].map(provider => (
        {provider, usage: {secondary: weekly}}))));
    assert.equal(detailedLabel(rows, 'remaining', {maxProviders: 2}), 'CX 7D 61%  ·  CL 7D 61%  +2');
    assert.equal(detailedLabel(rows, 'remaining', {maxProviders: 0}).split('  ·  ').length, 4);
    assert.equal(detailedLabel(rows.slice(0, 1), 'remaining', {maxProviders: 2}), '7D 61%');
    // The hidden providers are still in the model, so the popup and notifications keep them.
    assert.equal(rows.length, 4);
});

test('a per-model cap never becomes the tray headline while the provider reports its own quota', () => {
    // Cursor reports its monthly total as primary and a separate weekly Grok allowance.
    const rows = model.rows(JSON.stringify([{provider: 'cursor', usage: {
        primary: {usedPercent: 25, windowMinutes: 43200},
        extraRateWindows: [{id: 'cursor-grok-bot', title: 'Grok Bot', window: {usedPercent: 100, windowMinutes: 10080}}]}}]));
    assert.equal(model.summary(rows, 'remaining'), 'cursor 75%');
});

test('the bar keeps its single leading percentage until detail is switched on', () => {
    const rows = model.rows(JSON.stringify([
        {provider: 'codex', usage: {primary: session, secondary: weekly}, pace: {secondary: {deltaPercent: 14}}},
        {provider: 'claude', usage: {primary: session, secondary: weekly}},
        {provider: 'gemini', usage: {secondary: weekly}}]));
    // Default: what this adapter has always drawn, including the two-provider limit and the count.
    assert.equal(compactLabel(rows, 'remaining'), 'CX 37%  ·  CL 37%  +1');
    assert.equal(compactLabel(rows, 'remaining'), model.summary(rows, 'remaining'));
    assert.equal(compactLabel(rows, 'used'), 'CX 63%  ·  CL 63%  +1');
    assert.equal(detailedLabel(rows, 'remaining', {maxProviders: 2}), 'CX 5H 37% · 7D 61% · +14%  ·  CL 5H 37% · 7D 61%  +1');
});

test('per-model caps and the provider count stay available without turning on detail', () => {
    const rows = model.rows(JSON.stringify([{provider: 'claude', usage: {
        primary: session, secondary: weekly,
        extraRateWindows: [{id: 'claude-weekly-scoped-fable', title: 'Fable only',
            window: {usedPercent: 100, windowMinutes: 10080}}]}}]));
    assert.equal(compactLabel(rows, 'remaining'), '37%');
    assert.equal(compactLabel(rows, 'remaining', {scopedCaps: true}), '37% · Fable 0%');
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: true}), '5H 37% · 7D 61% · Fable 0%');
});

test('a per-model cap is judged against what the bar actually shows, in either mode', () => {
    // Cursor bills a monthly total and scopes a weekly Grok allowance beneath it.
    const cursor = model.rows(JSON.stringify([{provider: 'cursor', usage: {
        primary: {usedPercent: 25, windowMinutes: 43200},
        extraRateWindows: [{id: 'cursor-grok-bot', title: 'Grok Bot',
            window: {usedPercent: 100, windowMinutes: 10080}}]}}]));
    // Compact: the exhausted cap is tighter than the quota on show, so it earns its segment.
    assert.equal(compactLabel(cursor, 'remaining', {scopedCaps: true}), '75% · Grok Bot 0%');
    // Detailed: the weekly lane is derived from that same cap, so it is not repeated.
    assert.equal(detailedLabel(cursor, 'remaining', {scopedCaps: true}), '7D 0% · 30D 75%');
    // Kimi reports its whole quota as an extra; the bar must not print it twice.
    const kimi = model.rows(JSON.stringify([{provider: 'kimi', usage: {extraRateWindows: [
        {id: 'kimi-monthly', title: 'Total usage', window: {usedPercent: 80, windowMinutes: 43200}}]}}]));
    assert.equal(compactLabel(kimi, 'remaining', {scopedCaps: true}), '20%');
    assert.equal(detailedLabel(kimi, 'remaining', {scopedCaps: true}), '30D 20%');
});

test('a promoted compact fallback is the quota its per-model extras must out-bind', () => {
    const rows = model.rows(JSON.stringify([{provider: 'antigravity', usage: {extraRateWindows: [
        {id: 'antigravity-compact-fallback-model-a', title: 'Model A', usageKnown: true,
            window: {usedPercent: 64, windowMinutes: null}},
        {id: 'image-model', title: 'Image model', usageKnown: true,
            window: {usedPercent: 0, windowMinutes: null}}]}}]));
    // The idle image pool says nothing the provider's own quota has not said.
    assert.equal(detailedLabel(rows, 'remaining', {scopedCaps: true}), 'Model A 36%');
    const tighter = model.rows(JSON.stringify([{provider: 'antigravity', usage: {extraRateWindows: [
        {id: 'antigravity-compact-fallback-model-a', title: 'Model A', usageKnown: true,
            window: {usedPercent: 64, windowMinutes: null}},
        {id: 'image-model', title: 'Image model', usageKnown: true,
            window: {usedPercent: 95, windowMinutes: null}}]}}]));
    assert.equal(detailedLabel(tighter, 'remaining', {scopedCaps: true}), 'Model A 36% · Image model 5%');
});
