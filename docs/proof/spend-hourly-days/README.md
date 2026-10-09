# Hourly navigation date reuse

Usage & Spend reuses the recorded-day list while navigating in Hour mode. Each immutable currency
group owns a synchronized, demand-driven cache. Summary-only menu builds do not derive dates;
the first chart read does that work, and later reads (including focused-day fallback and group
copies) share the resulting array. Rebuilding a group for new history, source visibility, reporting
range, selected day, or time zone creates a new empty cache. Cached state does not affect equality.

## Reproduce from this checkout

On macOS with the repository's Swift toolchain, run from the repository root:

```sh
python3 docs/proof/spend-hourly-days/reproduce.py verify
python3 docs/proof/spend-hourly-days/reproduce.py benchmark
```

Both commands run the committed `SpendTrendHourlyDaysTests` using the native debug build backend,
four build jobs, and the repository's scrubbed test environment. All inputs are synthetic. They do
not launch the menu bar application or probe accounts, browser cookies, or Keychain items.

The verification covers shared array storage across repeated and concurrent reads, equality before
and after cache population, returned-array value semantics, empty/partial history, recorded zero,
half-open boundaries, hidden/replaced sources, range/selection changes, time-zone changes, 23/25-hour
days, Lord Howe half-hour transitions, and Sao Paulo's midnight transition. The storage assertion
fails on main's repeated date derivation without any wall-clock threshold.

The benchmark prints one `HOURLY_DAYS_BENCHMARK` JSON record. It compares the original date-list
function with the current cached function on 35,020 hourly points from four synthetic sources over
365 days. Fifteen calls per batch run in baseline/cached/cached/baseline order on the main thread;
the initial cold read is measured separately. Both implementations must return identical complete
date lists. CPU and elapsed times are observations, not test assertions. Debug timings on a shared
host measure this computation only, not click-to-paint latency, frame rate, energy, or users' history.

For broader regression coverage:

```sh
source Scripts/test_environment.sh
swift test --build-system native --jobs 4 -Xswiftc -gnone --no-parallel --filter 'SpendTrend|SpendDashboard'
make check
```

## Historical evidence

The contributor's Release Settings prototype, instrumentation, native-action measurements and eleven
matching compatibility records remain in commit `0dfac40f882dd81b3f4e74f74fa781fc33793419` on PR #4380.
Their fixture and instrumentation hashes were verified during review. That prototype eagerly indexed
every group and added construction cost to menu summaries. The current implementation derives dates
on demand, so its reproducible proof uses the current production implementation directly through tests.
The old launcher, patches and generated receipts are no longer needed in the shipped checkout.
