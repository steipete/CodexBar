# A Device Identifier belongs to the Mac, not to CodexBar's local state

The Device Identifier was a random UUID minted into `UserDefaults` on first launch, so it
identified CodexBar's local state rather than the Mac. Reinstalling produced a second Device
Identifier, and the Fleet gained a Stale Device holding Usage Snapshots nothing would ever
refresh (issue #3234). It is now derived from a hashed `kern.uuid`, which the Mac keeps across
reinstalls, so one Mac claims one Device Record.

## Considered Options

The derivation applies **only when no Device Identifier is already persisted**. A Mac that
already has one keeps it.

Re-keying every Mac to the derived Device Identifier at once was rejected. It does not avoid a
Stale Device, it only moves when one appears: either way each Mac in the Fleet strands its
random Device Identifier exactly once. Re-keying strands it on the update that ships this
change, with the user having done nothing to invite it; waiting strands it on the next
reinstall, an act the user took and can connect the Stale Device to. A Mac that never
reinstalls again is never charged at all.

## Consequences

Every Mac syncing today creates one more Stale Device, at its next reinstall, where the derived
Device Identifier replaces the random one. Reinstalls after that strand nothing. Stale Devices
from before this change stay in the Fleet. All of them are removed by hand from
Settings → iCloud Sync (see ADR 0002), which is what makes deferring the cost acceptable.
