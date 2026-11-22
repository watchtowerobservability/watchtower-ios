# Watchtower (Swift)

[![CI](https://github.com/watchtowerobservability/watchtower-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/watchtowerobservability/watchtower-ios/actions/workflows/ci.yml)

Watchtower SDK for iOS: crashes, hangs, app start, slow/frozen frames, RUM batches and screenshot replay that masks text and inputs by default, with an offline buffer.

Status: 0.x, early. APIs may change between minor versions.

## Install

Swift Package Manager: add `https://github.com/watchtowerobservability/watchtower-ios` and pick a version tag.
CocoaPods: `pod 'WatchtowerSDK'` (then `import WatchtowerSDK`; the pod is not named `Watchtower` so it cannot clash with the Flutter plugin's `watchtower` pod).

## Use

```swift
import Watchtower
var c = Config(key: "<publishable-key>", service: "ios-app")
c.endpoint = "https://<your-edge>"  // the default is a placeholder
Watchtower.start(c)
```

Use a publishable key here, never a secret ingest key.

Screens: every shown `UIViewController` is a RUM `view` (`c.trackViews = false` turns the
swizzling off); slow and frozen frame vitals carry the current screen. SwiftUI hosting
controllers are skipped; record SwiftUI screens with `Watchtower.shared.record(Event(type: "view", name: "Cart"))`.

Storage: `Datastore.instrumentSQLite(handle, name: "app.db")` (GRDB `db.sqliteConnection` in
`prepareDatabase`, SQLite.swift `connection.handle`, FMDB `db.sqliteHandle`), `Datastore.instrumentCoreData()`,
`Datastore.measure("realm", "write") { ... }` for SwiftData, Realm and others, and
`Datastore.recordStoreSize(system: "sqlite", url: storeURL)`. Slow or failed operations become `db` events;
main-thread work over one frame is flagged `db.main_thread`. Statement text is never sent.

Network: `URLSession.shared` requests become `resource` events (`c.trackNetwork = false` turns it
off). For your own sessions call `Watchtower.instrument(configuration)` before creating them.
Hosts in `c.propagateTo = ["https://api.example.com/"]` also get a W3C `traceparent` header.

Session end: on the next launch the previous session gets `session.end_reason`. A run that ended
without a crash report, `willTerminate`, an app or OS update or a reboot is reported as `oom` (in
the foreground) or `watchdog` (in the background). Stopping the app from the Xcode debugger looks
the same, so expect such endings during development.

MetricKit (iOS 14+): crash, hang and CPU-exception diagnostics arrive on a later launch and
become error events tagged `crash.source: metrickit` (`c.metricKit = false` turns it off). A crash
the SDK's own handler caught can show up a second time from MetricKit; filter on `crash.source`.

## App id

The SDK sends the app's bundle id (`Bundle.main.bundleIdentifier`) as `X-Watchtower-App-Id`. An app sends no `Origin`, so add that bundle id to the publishable key's **app ids** (Settings, Browser keys) or the edge refuses its events and feedback with 403 `app_id_not_allowed`.

## User feedback

```swift
Watchtower.shared.feedback("The checkout button does nothing", name: "Ann", email: "ann@example.com") { ok in }
```

It is linked to the last error the SDK recorded (or pass `eventId:`). Name and email become
pseudonyms at the edge. `ok` is false when nothing was sent; it never throws.

## Crash-loop guard

A crash within 5 s of `start` is a launch crash; such crash events carry `crash.launch`,
`crash.since_launch_ms` and `crash.loop_count`. `Watchtower.shared.launchCrashCount` counts the
consecutive launches that ended in one, and `isCrashLooping` is true from
`c.crashLoopThreshold` (default 2). Check it right after `start` to enter a safe mode:

```swift
Watchtower.start(c)
if Watchtower.shared.isCrashLooping { skipRemoteConfig(); clearCaches() }
```

## Provenance

Every release artifact carries a GitHub build attestation. Verify one with
`gh attestation verify <file> --repo watchtowerobservability/watchtower-ios`.

## License

Apache-2.0. Source of truth is the Watchtower monorepo; this repository is a published mirror.

## Symbolication (dSYM upload)

Add `scripts/upload-dsyms.sh` as a Run Script build phase (see the header of the script). It
splits universal dSYMs per architecture and calls `wtctl debug-files upload`; credentials come
from `WT_API`, `WT_API_KEY`, `WT_PROJECT` in the environment. Set `Config.buildId` to tag errors
with the build. Errors carry `replay.session_id` when replay is on.

## Publishing (owner step)

SwiftPM: a `v*` tag on the mirror. CocoaPods: the release workflow runs `pod trunk push` when the
repository secret `COCOAPODS_TRUNK_TOKEN` is set.
