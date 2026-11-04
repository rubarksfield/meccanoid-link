# First physical hardware pilot

**Status: native Mac connection, lights and driving are operator-confirmed. The operator reported no visible joint movement in either the corrected +3 trial or the 8-unit comparison.** A changed position display in the latter trial is not physical proof. Wheel direction, physical pulse duration and stopping have not been independently verified. An operator must be present for further hardware testing. Practice mode and simulator results are not hardware evidence.

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
| Initial single-write nudges | With operator readiness confirmed, isolated +3 raw-unit nudges requested for UI slot 3; app logged accepted mode and pose writes; feedback remained 33. On the observed retry the operator reported no movement, but a right-elbow light flash |
| Bounded refresh retry | Ten identical pose frames requested UI slot 3 from 33 to 36 within one second. Feedback remained 33; the operator reported only a light flash and no movement |
| Stop | Stop requested after the bounded retry; the app visibly disabled movement |
| Wheels | In a subsequent report, the operator confirmed that the driving commands work. Direction, physical pulse duration, Stop and timeout behaviour were not independently verified |
| Operator report before the mode-order fix | Lights work, but joint controls produce no visible movement. The operator suggested that the nudge might be too small; this remains a hypothesis |
| iPhone/iPad hardware | Not tested; builds do not establish physical Bluetooth operation |

Stop submission and disabled controls do not establish that every actuator physically stopped. No mechanical mapping, calibration, wheel-direction or lost-link stopping claim is made from this pilot.

The flash is an observation, not confirmation that slot 3 drives the right elbow. The nudge path also changes servo mode and sends a complete pose, so the flashing module cannot yet establish the selected slot's mechanical identity. No increase in range was made during those initial trials.

The bounded refresh has now received a supervised physical test. It did not resolve the observed lack of movement, so it is not recorded as a movement fix. The operator separately confirmed that the robot's arms move normally through its onboard controls and voice commands.

The later operator report establishes observed driving and lighting operation on this robot. It does not establish calibrated wheel speed, correct directional labels, reliable stopping or operation after a timeout. The joint controls remain unresolved; a larger nudge has not been established as the remedy.

## Read-only follow-up: 2026-11-04

A separate diagnostic read configuration, logical mapping and servo mode after the failed movement trial. It disconnected after the reads. No mapping or firmware write was made, and the wiring was not changed.

| Read | Evidence |
| --- | --- |
| Configuration `02` | Servos detected at CH1A, CH1B, CH3A and CH4A; eyes detected at CH2A |
| Reply `03` | All-zero data |
| Logical map | `22 21 20 00 01 02 10 11`, followed by eight `FF` entries |
| Mode `0A` | Value 4 only at zero-based logical indices 2, 3 and 4, corresponding to UI slots 3, 4 and 5 |

The map includes three of the four detected servos; CH4A is missing. This discrepancy is confirmed, but the tested UI slot 3 already maps to CH3A, a detected servo. The discrepancy alone is therefore insufficient to explain that slot's lack of movement. The mode readback is evidence of the later diagnostic state, not proof of what caused the trial to fail.

The app implements **Read robot layout** under Connection details and has passed native Mac and unsigned iOS/iPadOS arm64 builds. The Mac practice interface displayed simulated inventory, mapping and mode codes while movement remained disabled. The native diagnostic interface was subsequently checked against the physical robot as described below. It does not repair mappings or establish a slot's mechanical identity.

## Native app mode check: 2026-11-04

The operator connected the physical robot to native Mac app commit `656a339`. Movement remained disabled throughout this check.

| Step | Commands and observation |
| --- | --- |
| First **Read robot layout** | `02 → 03 → 20 → 0A` returned mode 2 at zero-based logical indices 2, 3 and 4, corresponding to UI slots 3, 4 and 5 |
| **Read position** | The app sent only `09`; no `0B` mode-setting or `08` pose command was sent |
| Second **Read robot layout** | The same configuration and mapping were returned, but mode was now 4 at those same indices |

This physically verifies the native app's layout-reading interface and records a mode 2 → 4 change across the `0A → 09 → 0A` sequence. A command-order effect is a candidate explanation, but the sequence did not isolate whether `0A` also changes servo state. It does not establish `09` as the sole cause.

The implemented correction reads and freezes the current pose first, sends mode 2, requires a `0A` reply confirming mode 2 for the selected slot, and only then sends the bounded target. The subsequent trial retained the ±3-unit limit. Every target handoff must precede the frozen baseline's absolute two-second expiry; the refresh also lasts at most one second. Movement using this corrected sequence has not been physically confirmed. The mode observations above came from the native app; no separate CLI control session completed or issued additional pose or mode commands during that check.

## Corrected sequence verification

The native Mac practice test completed **Find connected joints → blue eyes → confirm → enable movement → joint 1 +3 → Stop**. Simulated feedback changed from 128 to 131, and Stop disabled movement. The demo models one candidate explanation by resetting reported servo modes to 4 on `09`; this does not isolate the real firmware's `0A` behaviour. Native Mac and unsigned iOS/iPadOS arm64 builds passed.

The current joint picker requires a layout reading and offers only configured servo entries among the first eight logical slots. It does not assign anatomical names or repair the missing mapping entry.

## Corrected sequence physical trial: 2026-11-04

The operator restarted the robot and reconnected the corrected app. **Find connected joints** offered UI slot 3 as a configured servo. Movement was armed for an operator-supervised +3 trial from baseline 33 to target 36. The app recorded:

```text
Joint 3 reported mode 2 before its position command
Joint 3 target 33 → 36 accepted for bounded refresh
Bounded joint refresh finished after 9 frames
Joint 3 feedback unchanged at 33 after target 36
```

Stop was clicked and the app showed movement disabled. The operator then confirmed: “Nothing moved; try eight units.” The unchanged feedback and visual report agree for this +3 trial. The corrected order and mode check executed, but they were not sufficient to produce observed movement in this test.

The app defaults to 3-unit nudges and offers an explicit 8-unit selection; the controller bounds requests to ±8. The operator requested the comparison below. The pose-sampling order, mode checks, pacing and deadlines were unchanged so the selected comparison changed only the delta.

## Eight-unit comparison: 2026-11-04

The first attempt on joint 3 reported mode 4 instead of the required mode 2. The guard blocked the attempt, sent no `08` pose command and disabled movement. A retry on the same connection completed the nudge flow. The captured app log records:

```text
Joint 3 reported mode 2 before its position command
Joint 3 target 30 → 38 accepted for bounded refresh
Bounded joint refresh finished after 9 frames
Joint 3 feedback 30 → 33 after target 38
```

Stop was clicked, `0D` and `19` stop requests were logged, and movement was confirmed disabled in the app. A later Bluetooth disconnect cleared motion state; the UI showed a timeout. The operator reported “No visible movement.” Feedback changed from 30 to 33, below target 38, but does not establish an achieved eight-unit change or visible physical joint movement. Joint control and possible side effects of the `0A` mode query remain unresolved.

## Visual hardware observations

The controller label confirms model 91763. Connections are visible at ports 1–4, with ports 5–8 empty. The Robot selector appears to be in its left position; its selected mode has not been independently established. A red servo indicator is visible, but its colour alone does not establish an error, control mode or movement. These observations do not establish electrical continuity or anatomical mapping.

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

The app labels joints as numbered logical slots because wiring and mechanics can differ. Only configured servo entries among the first eight slots are offered after discovery. The app does not know their anatomical identity, physical neutral position or safe travel.

1. Keep movement disabled and choose **Find connected joints**. Wait for the layout reading to finish.
2. Select one offered slot and arrange support and clearance for the entire robot. Complete the eye-confirmation step, then explicitly enable movement.
3. Start with the default 3-unit nudge. The separate 8-unit selection is for an explicit bounded comparison. The app obtains a fresh pose and verifies control mode before sending the target; observe which part moves and in which direction.
4. Stop if the response is unexpected, a joint strains or another part moves. Use the physical power switch if needed.
5. Record the starting raw position, requested change and observed result. A returned position value alone is not proof of correct wiring or mechanical clearance.

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
