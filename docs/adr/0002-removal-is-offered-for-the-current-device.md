# Removal is offered for the current Device too

Issue #3234 asked for a way to remove a Stale Device, and the triage note scoped that to
"a selected non-current device". CodexBar offers it for every Device in the Fleet, including
the one running the app.

## Considered Options

Hiding the control on the current Device's row was rejected. It is the only way to reset this
Mac's own Device Record and Usage Snapshots, and a Fleet that has accumulated a Stale Device
usually wants that reset available on the Mac the user is sitting at.

Removal is not permanent for a live Device, and that is what makes offering it safe: the next
time syncing starts, `queueDeviceRecord` re-registers this Mac and cancels the queued delete
for its own record, so the Device Record comes back and its Usage Snapshots repopulate as they
are read again.

## Consequences

Removing the current Device reads as a reset rather than a deletion. The row disappears, the
Usage Snapshots stop being projected into the menu, and both return on the next sync start.
A user who wants the record gone for good has to turn syncing off after removing it.
