# Hyper-V RCT design

## Goal

Use Hyper-V Resilient Change Tracking (RCT) and backup/reference-point primitives to synchronize only blocks changed since a known migration reference point.

## Non-goals

The following are explicitly not considered a correct RCT implementation:

- copying an `.avhdx` file and calling it incremental replication
- merging checkpoint chains on a live production VM without a validated workflow
- scanning an entire virtual disk every synchronization cycle when Hyper-V changed-block metadata is available

## Required capabilities

The Hyper-V side eventually needs operations equivalent to:

```text
CreateReferencePoint
QueryChangedBlocks(reference-point)
ReadChangedRanges
AdvanceReferencePoint
RemoveReferencePoint
```

The exact implementation will be selected after validation against the Hyper-V versions used for testing.

## State requirements

For each virtual disk, persist at minimum:

- stable disk identity
- source VHDX path
- virtual size
- current reference-point identifier
- previous reference-point identifier
- last successful sync timestamp
- destination disk mapping
- checksum/validation metadata where practical

A reference point must not be advanced until all changed ranges for that synchronization have been durably applied to the destination.

## Sync transaction

Conceptually:

```text
source reference A
      │
      ├── query blocks changed since A
      │
      ▼
transfer/apply changed ranges
      │
      ├── validate destination writes
      │
      ▼
create/commit reference B
      │
      └── B becomes next sync baseline
```

If transfer or apply fails, reference A remains authoritative and the operation can be retried.

## Cutover

The final sync runs only after the source is quiesced/stopped. No source writes are allowed between completion of the final changed-block query and destination activation.

## Current implementation status

Not implemented yet. Phase 1 deliberately provides discovery and production-checkpoint baseline tooling first so that the basic migration path can be proven before RCT code is allowed anywhere near a live VM.
