# Contributing

Keep changes small and state the behaviour they improve. Read the relevant source and tests before editing. Protocol changes should link to primary evidence or include an anonymized reproducible hardware observation.

From the checkout root, run the nearest relevant checks:

```sh
swift test
./script/build_and_run.sh --build-only
xcodebuild -project MeccanoidLink.xcodeproj -scheme MeccanoidLink \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ci-ios CODE_SIGNING_ALLOWED=NO build
```

For UI changes, also inspect practice mode on the affected screen sizes. For connection or motion changes, test session transitions, malformed replies, cancellation and delayed callbacks where applicable. A software test is not a hardware test.

Preserve the separate eye-confirmation and movement gates. Do not introduce automatic movement on launch, scan, connection or reconnection. Do not increase motion limits without a clear rationale and physical evidence for the intended hardware.

Pull requests should describe what changed, the checks run and remaining limitations. Use the [hardware pilot report](hardware-pilot.md) for robot compatibility findings. Remove personal paths, device identifiers, credentials and unrelated logs or screenshots before sharing.

Only contribute material you have permission to distribute. Preserve the [MIT licence](../LICENSE) and [third-party notices](../THIRD_PARTY_NOTICES.md). Do not add manufacturer app binaries, firmware, decompiled code, audio or artwork.
