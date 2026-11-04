# Meccanoid Link

A native SwiftUI controller for Meccanoid robots on **iPhone, iPad and Mac**. It connects directly to the original MeccaBrain over Bluetooth Low Energy. No replacement controller, firmware flashing, browser, account or cloud service is required by this app.

**Experimental alpha. Bluetooth connection and blue eyes are physically confirmed through the native Mac app on one model 91763 MeccaBrain.** The operator confirmed the blue-eye change on 4 November 2026. Small joint nudges have not produced confirmed movement: the operator observed a right-elbow light flash, and the reported position stayed unchanged. Wheels and physical iPhone/iPad control remain untested. See the [hardware evidence](docs/hardware-pilot.md).

Builds, automated checks and practice mode cannot establish joint travel, wheel direction or reliable stopping. Compatibility with each robot generation and firmware remains unverified.

The initial target is the stock G15/G15KS-era MeccaBrain interface, including the model 91763 controller. This is an independent community project, unaffiliated with Meccano or Spin Master.

## What is implemented

- Explicit Bluetooth scanning, robot selection, service discovery and PIN handshake.
- Eye-colour commands with operator confirmation before movement can be enabled.
- Eight raw servo slots, with fresh position reads before small joint nudges.
- Short wheel-pulse controls and a prominent Stop action.
- Connection timeouts, status polling and reset of movement permission on disconnect.
- Practice mode with a simulated robot and no Bluetooth access.

The app uses only Apple frameworks and the local Swift package in this repository. There are no external Swift package dependencies, analytics, network requests or downloaded runtime assets. Bluetooth permission is requested when you choose to scan. Diagnostics stay in memory for the current app session.

## Build and run

Requirements: a Mac with a recent Xcode supporting Swift tools version 6.0. The deployment targets are **iOS/iPadOS 17** and **macOS 14**. The package currently uses Swift 5 language mode. The Mac target is native macOS, not Catalyst.

From the checkout root, start with the simulation:

```sh
./script/build_and_run.sh --demo --verify
```

The script builds the native Mac app, launches it and verifies the process. It stops only an earlier instance running from this checkout's exact build path. The Codex Run action uses the same script, without practice mode.

Other useful commands:

```sh
./script/build_and_run.sh --build-only
./script/build_and_run.sh             # Real Bluetooth mode; scanning is explicit
swift test
open MeccanoidLink.xcodeproj
```

Mac builds use ad-hoc signing by default. To use your own Apple development team, set `MECCANOID_DEVELOPMENT_TEAM` locally or choose a team in Xcode. No developer identity or provisioning profile is committed.

For iPhone or iPad, open `MeccanoidLink.xcodeproj`, select the `MeccanoidLink` scheme and choose your device. Set your own team under Signing & Capabilities, then Run. To explore the interface in Simulator, add `--demo` under Scheme → Run → Arguments. Simulator practice mode does not test Bluetooth hardware.

The [CI workflow](.github/workflows/ci.yml) runs package tests and unsigned native Mac and iOS Simulator builds. It does not pair with a robot or verify physical behaviour.

## First connection

Follow the [hardware pilot](docs/hardware-pilot.md) when an operator and robot are available. Start with a charged battery, normal robot startup and USB disconnected. Select the robot in the app, allow Bluetooth access and press the robot's yellow button if it requests connection.

Send one eye colour and observe the robot. A successful Bluetooth write means the command was submitted, not that the eyes changed. Confirm the change only after seeing it. Movement still requires a separate explicit enable action.

The initial movement limits are intentionally small:

| Control | App behaviour | What remains unknown |
| --- | --- | --- |
| Joint nudge | At most ±3 raw units after a fresh complete pose; refreshes the same target for up to one second, preserving the other seven values | Physical movement, joint identity, degrees, direction and mechanical limits |
| Wheels | At most ±40 raw PWM units; schedules zero-speed after 250 ms | Actual speed, direction and physical pulse duration |
| Stop | Cancels queued motion and sends zero-wheel plus a firmware-specific stop request | Whether every actuator stops on each firmware |

The wheel timer runs in the app; it is not an onboard watchdog. A lost link, suspended app or delayed Bluetooth write can prevent a stop command from reaching the robot. Keep the physical power switch accessible. The protocol range of 24–232 for a joint nudge is not a calibrated safe range for your assembly.

## Source layout

| Path | Purpose |
| --- | --- |
| `App/` | Adaptive SwiftUI interface and app lifecycle |
| `Sources/MeccanoidCore/` | Pure packet encoder, checksum validation and reply types |
| `Sources/MeccanoidBluetooth/` | CoreBluetooth transport, session state and simulated transport |
| `Tests/` | Automated package tests |
| `Config/` | Mac Bluetooth sandbox entitlement |
| `script/` | Project-local Mac build and launch commands |

The [protocol notes](docs/protocol.md) describe the 20-byte BLE frames and evidence boundaries. Firmware updates, sound uploads, speech recognition, recorded sequences and calibrated joint control are outside this alpha.

## Contributing and licence

See [contributing](docs/CONTRIBUTING.md) for verification and hardware-report guidance. Contributions that improve compatibility should identify the robot generation, firmware if known and what was physically observed.

Licensed under [MIT](LICENSE). The protocol/controller work draws on Chris Nesbitt-Smith's Robot club project; its MIT notice and pinned source references are preserved in [third-party notices](THIRD_PARTY_NOTICES.md). No original vendor app binaries, firmware, decompiled source, artwork or audio are included.
