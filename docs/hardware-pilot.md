# First physical hardware pilot

**Status: native Mac connection and blue eyes confirmed; movement validation incomplete.** An operator must be present for further hardware testing. Practice mode and simulator results are not hardware evidence.

## Diagnostic evidence: 2026-11-04

The original MeccaBrain was first visible to the Mac as a Spin Master USB device. The operator then powered it from its battery and disconnected USB. Testing used the upstream [native control diagnostic](https://github.com/chrisns/meccanoid/blob/929ab37efee7b2615e71dadd1589eaf53e72dcb1/tools/control.swift), not this repository's SwiftUI app.

| Check | Evidence |
| --- | --- |
| Bluetooth discovery | Meccanoid advertisement found |
| PIN handshake | Accepted reply received |
| Status | Valid reply received; raw battery code 4 and error code 0 |
| Joint positions | Eight raw slot values returned; physical joint mapping and calibration unverified |
| Red eyes | Red command sent; operator explicitly confirmed the eyes were red |
| Movement | No movement commanded or tested |

The red-eye observation verifies a physical effect through that diagnostic on this robot. The status codes are raw values, not calibrated battery measurements. It does not establish compatibility with other firmware, mechanical limits or reliable stopping. The app's separate test follows below.

## Native Mac app evidence: 2026-11-04

The first app connection attempt timed out before notification subscription. Neither controller then rediscovered the robot. After the operator restarted it, the SwiftUI Mac app connected successfully. The earlier failure's cause was not established.

| Check | Evidence |
| --- | --- |
| App handshake | App entered its connected state after an accepted PIN reply |
| Blue eyes | Blue button used in the app; operator explicitly confirmed blue eyes |
| Eye gate | Operator confirmed the visible change in the app |
| Position read | App received joint-position data |
| Joint nudge | With operator readiness confirmed, one +3 raw-unit nudge requested for slot 3; app logged accepted mode and pose writes; physical effect awaiting operator report |
| Stop | Stop requested after the nudge; zero-wheel and stop-preset writes accepted; app visibly disabled movement |
| Wheels | No nonzero wheel command requested |
| iPhone/iPad hardware | Not tested; builds do not establish physical Bluetooth operation |

Stop submission and disabled controls do not establish that every actuator physically stopped. No mechanical mapping, calibration, wheel-direction or lost-link stopping claim is made from this pilot.

## Prepare

Use a stable, clear area and support the robot so an unexpected movement cannot cause a fall. Inspect its assembly and cables. Use the correct charged battery pack and confirm normal startup with USB disconnected. Leave the physical power switch reachable throughout the test. Follow the robot's own operating instructions.

Record the robot generation, controller model and firmware if available. Do not change firmware or wiring as part of this first test.

## Connect and verify the eyes

1. Launch the app without `--demo`. Choose **Find my robot**, then the intended robot. Allow Bluetooth access if requested.
2. Press the yellow chest button if the robot asks to connect. Record whether the prompt occurred and whether the app completed the handshake.
3. Choose one eye colour and watch the actual robot. Record separately whether the app submitted the command and whether the eyes visibly changed.
4. Try a second distinct colour. If the eyes do not change as expected, disconnect and investigate before enabling movement.
5. Use the eye-confirmation action only after observing the change. Leave movement disabled until the robot is ready for a controlled trial.

## Establish one joint at a time

The app labels joints as numbered slots because wiring and mechanics can differ. It does not know the physical neutral position or safe travel of your build.

1. Arrange support and clearance for the entire robot, then explicitly enable movement.
2. Read the positions. Select one populated slot, choose a single small nudge and observe which part moved and in which direction.
3. Stop if the response is unexpected, a joint strains or another part moves. Use the physical power switch if needed.
4. Record the starting raw position, requested change and observed result. A returned position value alone is not proof of correct wiring or mechanical clearance.

Do not sweep to the protocol endpoints to discover limits. Mechanical calibration is separate future work. The alpha does not automatically restore a baseline pose after a nudge.

## Wheels and stopping

Only attempt wheels after the eye test and with the robot safely supported and clear of obstacles. Make one wheel-control request at a time. Confirm actual direction and that motion ceases after the short pulse. Check Stop while the connection is healthy before broader use.

The app requests a maximum magnitude of 40 raw PWM units and sends zero-speed after an app-side 250 ms delay. Transmission, firmware behaviour and physical coast-down affect the result. Do not interpret that delay as a guaranteed physical duration.

Stop requires a functioning connection. Bluetooth loss or app suspension can prevent the request from arriving, and the firmware-specific stop preset is unverified here. Keep the power switch available. Do not deliberately break the link while the robot is moving during this pilot.

## Record the result

Use a report like this, omitting private device identifiers and unrelated surroundings:

```text
App commit / build:
Platform and OS:
Robot generation / controller model:
Firmware, if known:
Power and startup:
Handshake prompt and outcome:
Eye command submitted / observed effect:
Joint slot, baseline, requested delta / observed effect:
Wheel command / observed direction and stop:
Stop requested / observed effect:
Unexpected behaviour:
```

Mark each feature as **not tested**, **command submitted**, **reply received** or **physical effect observed**, as appropriate. A successful result on one firmware does not establish compatibility with all Meccanoid variants.
