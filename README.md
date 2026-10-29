# Watchtower (Swift)

[![CI](https://github.com/watchtowerobservability/watchtower-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/watchtowerobservability/watchtower-ios/actions/workflows/ci.yml)

Watchtower SDK for iOS: crashes, hangs, app start, slow/frozen frames, RUM batches and screenshot replay that masks text and inputs by default, with an offline buffer.

Status: 0.x, early. APIs may change between minor versions.

## Install

Swift Package Manager: add `https://github.com/watchtowerobservability/watchtower-ios` and pick a version tag.

## Use

```swift
import Watchtower
var c = Config(key: "<publishable-key>", service: "ios-app")
c.endpoint = "https://<your-edge>"  // the default is a placeholder
Watchtower.start(c)
```

Use a publishable key here, never a secret ingest key.

## Provenance

Every release artifact carries a GitHub build attestation. Verify one with
`gh attestation verify <file> --repo watchtowerobservability/watchtower-ios`.

## License

Apache-2.0. Source of truth is the Watchtower monorepo; this repository is a published mirror.
