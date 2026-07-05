---
summary: "Repository size findings, prevention checks, and the maintainer-only history cleanup runbook."
read_when:
  - Adding large assets or release artifacts
  - Investigating clone size
  - Planning a Git history rewrite
---

# Repository size

The checked-out source tree is not the main cause of CodexBar's clone size. At commit `61ff9320`, tracked files total
22,292,801 bytes, while the packed Git object database is 103.91 MiB. `CHANGELOG.md` is 150,271 bytes in the current
tree and all of its historical blobs occupy about 0.55 MB compressed.

Most of the packed history comes from files that are no longer present on `main`:

| Historical path group | Approximate compressed bytes |
| --- | ---: |
| `screenshots/` | 39,023,716 |
| `Quotio/` | 23,141,837 |
| `CodexBar 2.app/` | 7,088,125 |
| `CodexBar-0.2.2.zip` | 2,296,323 |

The largest single blob is the retired `Quotio/Resources/Proxy/cli-proxy-api-plus` executable: 49,202,546 bytes
before compression and about 15.8 MB in the pack. Deleting these files in later commits stopped further growth but
did not remove their blobs from existing history.

## Prevention

`Scripts/check_repository_size.sh` runs under `make check`. It inspects the exact blobs in Git's index, not mutable
working-tree copies, and rejects:

- tracked files larger than 2 MiB;
- app bundles, dSYMs, Xcode results, IPAs, archives, deltas, disk images, and installer packages.

Publish release artifacts through GitHub Releases. Optimize required source images before committing them. If a
source asset genuinely must exceed the limit, discuss and review the limit change explicitly rather than bypassing
the check.

For a smaller local checkout when full history is unnecessary, use one of:

```bash
git clone --filter=blob:none https://github.com/steipete/CodexBar.git
git clone --depth=1 https://github.com/steipete/CodexBar.git
```

## One-time history cleanup

A normal pull request cannot reduce the size of already reachable Git objects. Maintainers can recover most of the
avoidable clone weight only with a coordinated history rewrite. Candidate paths that are absent from current
`main` are:

```text
screenshots/
Quotio/Resources/Proxy/cli-proxy-api-plus
CodexBar 2.app/
CodexBar_Dev.app/
CodexBar-0.2.2.zip
CodexBar6-2.delta
CodexBar6-4.delta
```

Use `git filter-repo` on a fresh mirror, validate all branches and tags, and force-push only during an announced
maintenance window. This changes commit and tag IDs and requires contributors to re-clone or carefully rebase, so
the rewrite must not be performed from a normal contributor branch.

An isolated mirror rehearsal using exactly the candidate paths above reduced the packed object database from
103.90 MiB to 41.99 MiB (59.6%) and passed `git fsck --full --no-dangling`. Treat this as a reproducible baseline,
not authorization to rewrite the canonical repository.
