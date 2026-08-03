---
layout: post
title: "Building a Super-Fast Key-Value Store From Scratch"
date: 2026-08-03
---

*Another entry in a self-imposed system design exercise (following Arpit Bhayani's course) — building the primitives a database gives you for free, from the ground up, to actually understand them.*

## The problem

Design a key-value store with:

- Super fast reads, writes, deletes
- Full persistence on HDD
- No traditional database underneath

The instinct to reach for MySQL and lean on its indexes was explicitly set aside — the point of the exercise is to build storage from scratch, not wrap an existing engine.

## Starting point: append-only writes

Assume a single server: 32GB of RAM, 512GB of HDD. The data lives in a flat file — say `file.txt` — with entries like `a: 1, b: 2, c: 3, z: 26`.

Adding a new entry (`d: 4`) has two options:

1. Walk the file and insert `d` in its correct sorted position — an O(n) operation involving moving everything after it.
2. Just append `d: 4` to the end of the file.

Option 2 wins: appending is O(1) and doesn't touch existing data. This is the foundational decision the rest of the design builds on.

## Reads: a hashmap of offsets, not a scan

A naive read would scan the file linearly until it finds the key (or reaches the end, having confirmed it doesn't exist) — slow, and gets worse as the file grows.

Instead: keep an **in-memory hashmap** where each key maps to its **byte offset** in the file on disk.

```
cache (RAM):        file (HDD):
a: fa1               a: 1
b: fb1               b: 2
c: fc1               c: 3
z: fz1               z: 4
```

A read becomes: look up the offset in RAM, seek directly to that byte position on disk, read until the next separator, return the value. No scanning.

Writes follow the same append-then-index pattern: append the new entry to the file, then add (or update) its offset in the in-memory hashmap. An update to an existing key (say `c: 10`) is *also* just an append — the file ends up with two `c` entries, and the hashmap's pointer for `c` is updated to point at the newer one. The stale entry is left in place for now; it becomes dead weight to be reclaimed later.

## Reclaiming space: merge/compaction

Over time, updates leave stale duplicate entries scattered through the file. A background **merge** process handles this: given `file1.txt` and `file2.txt`, walk both and produce `file3.txt` containing only the latest value for each key (later files win over earlier ones for any key present in both), then delete the old files to reclaim space.

Individual files are capped at a fixed size (e.g. 100MB) — once a file hits the cap, writes roll over to a new file, and merging continues recursively so files stay bounded rather than growing forever.

## Sizing the system

With a key/value ceiling of 100KB per key and 25MB per value, ~500GB of usable disk works out to roughly 20,000 values at maximum value size — no room left for keys at that ceiling, so in practice most values are far smaller than the 25MB max, and the real capacity is much higher.

For the 32GB RAM budget: at ~100 bytes per key and a 32-byte file-pointer value, RAM can comfortably hold far more keys than disk could realistically need to store at max value size — meaning in the common case, the entire key index fits in memory with room to spare.

But "on average the value is much smaller than max, and there's no guarantee every key fits in RAM" is worth stating plainly rather than assumed away — which raises the next question directly.

## Cache misses: index files instead of a full scan

If a key isn't in the in-memory hashmap — because it was evicted, or because the process just restarted — falling back to a full file-system scan defeats the entire point of the design. The fix: maintain an `index.txt` alongside each data file, listing every key present in that file. On a cache miss, scan the (much smaller) index files — in reverse order of recency — rather than the data files themselves. As an added optimization, a **bloom filter** in front of the index files can rule out "definitely not present" checks cheaply, at the cost of occasional false positives.

For value-level caching (once resolved), a simple eviction strategy like LRU keeps hot values in memory without needing to hit disk repeatedly for the same key.

## Deletes

Deletes reuse the append-only mechanism: write a tombstone marker (e.g. `$`) as the value for a deleted key. Since a raw `$` could theoretically collide with a legitimate value, wrap it in a delimiter the system doesn't treat as normal data. The merge process treats tombstones as instructions to drop the key entirely from the compacted output, rather than carrying it forward.

## Where the design review found real gaps

The mechanics above were largely solid on paper, but three questions — the kind a staff-level review is supposed to surface — exposed real gaps once traced through concretely.

### 1. Does the design actually survive a restart?

Every read depends on the in-memory hashmap. On a crash or restart, that hashmap is gone. The natural fallback — scan the `index.txt` files in reverse to rebuild — turns out not to be "fixed number of iterations" at scale: the 100MB-per-file cap bounds *file size*, not *file count*. At 512GB of data and 100MB per file, that's up to ~5,000 files, each requiring an HDD seek, just to resolve a cold cache. That directly contradicts the "super fast reads" requirement.

**Resolution:** periodically snapshot the in-memory hashmap itself to a separate file — distinct from the compaction/merge process, which solves a different problem (reclaiming disk space, not restart speed). On restart, load one compact snapshot instead of replaying history through thousands of index files.

For write safety, snapshot writes use length-prefixed records so a truncated write is detectable. If a snapshot write is interrupted mid-flight, the **entire file is discarded** rather than partially trusted — accepting that a rare interrupted write costs one slow cold-start scan, in exchange for a simpler write path than a full atomic-swap-on-write scheme would need. A deliberate trade, worth stating explicitly rather than leaving implicit.

### 2. What happens to a read racing an in-progress merge?

While `merge` builds `file3.txt` from `file1.txt` and `file2.txt` in the background, reads continue being served from the existing files and their indexes — nothing changes for in-flight traffic during the merge itself.

The harder question is the handoff once the merge completes. The initial instinct — wait until there are "no active connections" on the old files, then delete them — relies on an assumption that doesn't hold on Linux: deleting (`unlink`) a file that's still open by another process succeeds silently rather than raising an error. The file's name is removed from the directory immediately, but the underlying data (the inode) stays alive as long as *any* process still holds an open file descriptor to it — space is only reclaimed once the last handle closes.

**Resolution:** this actually resolves the race, once the ordering is right:

1. The in-memory cache pointer is updated to `file3` **first** — before anything is deleted.
2. Any *new* read arriving after that point resolves directly to `file3.txt`; it never looks at `file1.txt` again.
3. `file1.txt` and `file2.txt` are then unlinked. Their names disappear from the directory, but any reader that opened a handle to them *before* the pointer swap keeps working normally — the OS keeps their data alive until that handle closes.
4. Once the in-flight reader closes its handle, the space is actually freed.

Pointer-swap-before-delete means there's no window where a new request can race the deletion — new requests simply never reach the file being deleted in the first place.

### 3. When is a write actually durable?

The write path updates two things: the data on disk and the in-memory offset pointer. Which happens first, and when does the client get told the write succeeded, both matter for what "durable" actually means.

**Resolution:** disk write happens first, and the client only receives a success acknowledgment after that write is confirmed on disk (not just handed to an OS buffer). The in-memory pointer update happens after — and if a crash occurs between the disk write and the pointer update, the value is safely re-derivable by reading straight from disk on the next lookup, using the same cache-miss fallback path already built for cold starts. Disk is the single source of truth; the hashmap is always a rebuildable cache on top of it, never the other way around.

This does cost write latency — blocking on a durable disk write instead of acking immediately — but given the requirements explicitly call out fast *reads* and full *persistence*, not fast writes, that's the correct trade to make deliberately.

## What this maps to

This design — append-only writes, an in-memory hash index over file offsets, periodic compaction, sparse index files for fast lookups on a miss, and hint-file-style snapshots for fast restarts — is close in shape to a **Bitcask**-style log-structured store, one of the simpler members of the LSM-tree family. Naming it doesn't change anything about the design, but it's useful vocabulary to have on hand.

## Open threads for next time

- Sharding/multi-machine scaling to go beyond a single server's ~500GB ceiling — flagged as future work, not yet designed.
- The bloom-filter tradeoff (space saved vs. false-positive rate) hasn't been sized against real numbers yet.
- Corruption detection for the *data* files themselves (not just snapshots) — what stops a bad changelog or partial write from silently corrupting a merged file.
