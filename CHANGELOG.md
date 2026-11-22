# Changelog

## 0.1.1

- Sync with the monorepo: wireframe replay, symbolicatable NSException frames and launch profiling.

- Crashes and hangs show every thread: a fatal signal writes the other threads' stacks (Mach `task_threads`, frame-pointer walk), the next launch sends them with the loaded images (`threads`, `debug_images`, parsed `frames`) so the server symbolicates them against the uploaded dSYM. An app hang carries the main thread's stack and the other threads. Uncaught NSExceptions carry the other threads.
- Launch profiling: `Config.profileLaunch` (event `app_launch_profile`, folded stacks).
- Client storage (`Datastore`): `instrumentSQLite(handle)` (GRDB, SQLite.swift, FMDB via `sqlite3_trace_v2` profile), `instrumentCoreData()` (fetch, batch execute, save), `measure` for SwiftData/Realm/others, `recordStoreSize` (file + WAL). Slow or failed ops as `db` events, main-thread work flagged `db.main_thread`.
- Requests carry the bundle id in `X-Watchtower-App-Id`; list it in the publishable key's app ids.
- CocoaPods: `WatchtowerSDK.podspec` (module `WatchtowerSDK`).
- MetricKit crash, hang and CPU-exception diagnostics (`metricKit`, iOS 14+).
- `feedback(_:name:email:eventId:done:)` posts user feedback linked to the last error.
- Crash-loop guard: `launchCrashCount`, `isCrashLooping`, `crashLoopThreshold`; launch crashes are tagged `crash.launch`.

## 0.1.0

- Initial public release.
