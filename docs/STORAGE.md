# Local state and record synchronization

The SQLite database is the local durable source for preferences and history. It is not a synchronization payload.

## Locations and ownership

- `movebit.sqlite3` lives in the machine's application-data directory, or `MOVEBIT_DATA_DIR` / the local-directory bootstrap override. SQLite may also create `-wal` and `-shm` companions while open.
- `bootstrap.json` stays in the default machine-local directory. It contains device identity, local/sync directory pointers and updater bookkeeping. It is not exchanged between devices.
- Optional `MOVEBIT_SYNC_DIR` / bootstrap `sync-dir` selects a separate record-exchange directory. Disabled by default. It may live in a Resilio/Syncthing-style folder.
- The exchange directory must not contain the local database directory. Settings, bootstrap metadata, update payloads and database files are never exported. SQLite and exchange state must not be placed in a shared parent that is itself synchronized.
- The existing `get-data-dir` / `set-data-dir` RPCs describe the **local** data directory. `get-sync-dir` / `set-sync-dir` describe the independent exchange directory; an empty string disables exchange. Directory changes take effect after restart and do not move, delete or import data. Environment overrides take precedence.

## SQLite contract

The file has `application_id = 0x4d424954` and `user_version = 1`. Fresh files are initialized in an immediate transaction. Unknown schema versions and foreign databases are refused without replacement. Connections enable WAL, FULL synchronous writes, foreign keys and bounded busy retries; every operation closes its connection. Preferences are one atomic, versioned JSON value in the `settings` row; history uses typed columns in `records`, keyed by `(day, device)`, with a persisted revision and a cue-outcome map. `sync_state` keeps the durable retention watermark.

The retired `config.json` and monolithic `history.json` are not read or migrated. No dual persistence path remains. This follows the first-real-v1 clean-slate decision; a copied legacy file is not interpreted as current user state.

## Exchange and merge

A writer only publishes `history/YYYY-MM-DD/<8-hex-device-id>.json`. The envelope contains `SchemaVersion: 1`, `Date`, `DeviceId`, a positive 64-bit `Revision`, and the daily `Record`. Record fields are ActiveMinutes, SitBreaks, WaterReminders, MicroBreaks, LongestSessionMinutes and CueOutcomes. Snapshots are bounded to 64 KiB and all counters are nonnegative bounded integers. Dates, paths, identity and schema are validated before any database write. Symlinks, temporary files, malformed records and sync-tool conflict copies are excluded.

Each local save commits a monotone snapshot in SQLite before publishing a transport file. Same-device counters and cue outcomes take their component-wise maximum; unchanged saves do not advance the revision. An imported record replaces a missing/older revision transactionally; duplicate, conflicting equal-revision and stale arrivals do not write or add counters. Existing local-origin database rows are authoritative over their echoed files. A missing local row can be reconstructed from its valid transport snapshot. Distinct devices' additive counters sum, while longest-session takes the maximum. Restoration of the local scheduler uses only this device's record, never the cross-device total.

Committed local rows form a durable outbox. Publication uses a unique temporary file and atomic rename. An unavailable exchange folder does not roll back local data; the next refresh/restart republishes the current local snapshots, repairing lost or stale exports. Imported records are never republished as if locally observed. Refresh reads content rather than relying on second-resolution mtimes.

Retention remains 370 days. A monotone SQLite watermark rejects expired arrivals even after restart, preventing deleted history from being resurrected by old sync files. Only this device's expired transport files are removed; peers' files remain under their writers' ownership. File deletion or disappearance is not interpreted as a negative record or as consent to delete committed local history.

## Verification and recovery

Build environments require Racket `db-lib` in addition to Rivet. Full Racket distributions include it; minimal embeddable runtimes must install it explicitly before compiling the backend. The macOS and Windows release builds install it into that same runtime.

Tests use independent real databases and filesystem exchange, and cover restart, isolation, duplicates, out-of-order/equal-revision conflicts, corrupt/oversized/foreign records, symlinks, same-second updates, export failure and retry, retention replay and concurrent local writers. Wire tests assert actual SQLite persistence. Native acceptance fixtures seed through the real config API. Native controls and the reminder scheduler are unchanged.

Back up a stopped local profile as a whole (include bootstrap separately where it lives). Do not copy an open database without SQLite's backup API or a consistent WAL-aware snapshot. Restore to an isolated local directory first. Synchronization is not a backup and is not guaranteed to provide permanent retention. Schema changes require an explicit new version and a tested decision; a future/foreign/corrupt file is never silently replaced.
