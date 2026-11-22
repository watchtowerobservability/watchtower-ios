# CocoaPods distribution of the iOS SDK (Swift Package Manager stays the primary one). Named
# WatchtowerSDK, not Watchtower: the Flutter plugin's pod must be named after its Dart package,
# `watchtower`, and CocoaPods and the default case-insensitive macOS file system treat
# `watchtower` and `Watchtower` as the same pod directory and module. Swift code imports
# `WatchtowerSDK` under CocoaPods and `Watchtower` under SwiftPM (`#if canImport(WatchtowerSDK)`).
Pod::Spec.new do |s|
  s.name          = 'WatchtowerSDK'
  s.version       = '0.1.1'
  s.summary       = 'Watchtower iOS SDK: RUM, crashes, hangs, app start, frames and masked replay over the Watchtower edge.'
  s.license       = 'Apache-2.0'
  s.homepage      = 'https://github.com/watchtowerobservability/watchtower-ios'
  s.authors       = 'Watchtower'
  s.source        = { :git => 'https://github.com/watchtowerobservability/watchtower-ios.git', :tag => "v#{s.version}" }
  s.source_files  = 'Sources/Watchtower/**/*.swift'
  s.ios.deployment_target = '13.0'
  s.osx.deployment_target = '11.0'
  s.swift_version = '5.9'
end
