# CodexBar

Menu bar app that reports AI provider usage and credits. This glossary covers terms whose
meaning is specific to CodexBar and easy to confuse with a neighbouring concept.

## Language

### iCloud Sync

**Device**:
One physical Mac in the user's Fleet. A Device outlives reinstalls of CodexBar: reinstalling
does not produce a second Device.
_Avoid_: Machine, installation, node, client

**Device Record**:
The CloudKit record that represents a Device. One per Device.
_Avoid_: Mac record, host record

**Device Identifier**:
The value by which a Mac claims its Device Record. Two Macs never share one, and one Mac keeps
the same one across reinstalls of CodexBar.
_Avoid_: Device ID, install ID, client ID

**Fleet**:
The set of Devices syncing under a single iCloud account.
_Avoid_: Cluster, group, network

**Fleet Cache**:
This Mac's copy of the Fleet, as of its last fetch. It is authoritative up to that moment and
no further: anything published afterwards is missing from it until the next fetch.
_Avoid_: Local state, mirror, replica

**Usage Snapshot**:
What one provider account's usage was at one moment, as seen on one Device. Snapshots are
per-Device: two Devices reporting the same account hold separate Snapshots.
_Avoid_: Usage record, sample, reading

**Stale Device**:
A Device Record no live Mac will ever refresh, because no Mac claims its Device Identifier any
more. Its Usage Snapshots keep being projected into the menu even though nothing updates them.
_Avoid_: Orphan, ghost, dead device, duplicate
