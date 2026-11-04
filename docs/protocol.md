# Protocol and implementation notes

These notes describe the current Swift implementation. The compatibility target is the original MeccaBrain's Bluetooth interface. This is separate from the serial Smart Module bus between the controller and individual servos.

The implementation follows community protocol research and independently checked packet facts. [Third-party notices](../THIRD_PARTY_NOTICES.md) identifies the sources. On 2026-11-04, an upstream native diagnostic produced operator-confirmed red eyes. A separate test of this SwiftUI Mac app then completed its own connection and produced operator-confirmed blue eyes on the same model 91763 MeccaBrain. The operator subsequently confirmed that driving commands and lights work, but reported no visible joint movement before the command-order fix. Neither the earlier single-write nudges nor bounded ten-frame refresh produced confirmed joint movement; the operator observed only a light flash and feedback stayed unchanged. See the [hardware evidence](hardware-pilot.md) for the distinction between submitted commands, replies and observed effects. Wheel direction, physical pulse duration, stopping and timeout behaviour have not been independently verified. iPhone/iPad hardware remains untested.

## Bluetooth transport

| Role | Short UUID | Full UUID |
| --- | --- | --- |
| Service | FFF0 | `0000FFF0-0000-1000-8000-00805F9B34FB` |
| Notifications | FFF1 | `0000FFF1-0000-1000-8000-00805F9B34FB` |
| Command writes | FFF2 | `0000FFF2-0000-1000-8000-00805F9B34FB` |

The scanner displays advertisements whose names begin with `MECCANOID`, case-insensitively. It scans without a service filter because some old firmware may omit FFF0 from advertisements. After the operator selects a device, the transport requires the service and characteristics above.

The transport subscribes to FFF1 before sending the handshake. It prefers writes without response when advertised, otherwise uses writes with response. CoreBluetooth accepting a write is not a robot-level acknowledgement or physical observation.

## Frames

Every frame is 20 bytes:

| Offset | Content |
| --- | --- |
| 0 | Command byte |
| 1–17 | Seventeen payload bytes |
| 18–19 | Big-endian sum of bytes 0–17 |

Unused payload bytes are zero unless the command specifies otherwise. Incoming frames with the wrong length or checksum are ignored.

The PIN request is:

```text
1A 01 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 1C
```

A valid `1A` reply is considered only while handshaking. The known rejected reply prefix is payload `00 01 FF`. After acceptance the controller sends zero-wheel and status commands. No nonzero wheel or servo-pose command is sent merely by connecting.

## Commands currently encoded

| Hex | Meaning | Payload |
| --- | --- | --- |
| `01` | Read status | Zero-filled |
| `02` / `03` | Read module types for channels 1–4 / 5–8 | Zero-filled; replies contain sixteen type bytes |
| `08` | Set complete pose | Eight raw positions followed by nine `01` bytes |
| `09` | Read pose | Zero-filled; reply positions are bytes 1–8 |
| `0A` | Read servo modes | Zero-filled; reply contains sixteen raw mode bytes |
| `0B` | Servo mode | Sixteen `02` bytes for control, or sixteen `04` bytes for read mode; final byte zero |
| `0D` | Wheels | Left direction, right direction, left magnitude, right magnitude, `FF FF`, then zeros |
| `11` | Eyes | `00 00`, `(green << 3) \| red`, blue, then zeros; each channel 0–7 |
| `19` | Stop preset request | `08 00`, then zeros |
| `1A` | PIN handshake | `01 00 01`, then zeros |
| `20` | Read logical servo mapping | Zero-filled; reply contains sixteen address bytes |

Wheel direction codes are `01` for requested forward and `02` for requested reverse; zero-wheel frames use `02` with magnitude zero. The codec accepts signed raw magnitudes up to 100. The interactive controller further limits them to 40 and schedules zero-speed after 250 ms. These values are not percentages or calibrated speeds.

The operator reports successful driving through the app. That observation does not independently verify the direction-code interpretation, the physical duration of a pulse or the effect of Stop and timeout handling.

Preset 8 is the stop entry reported for a community-tested G15KS firmware bank. Its meaning and effect are firmware-dependent. It is not a guaranteed emergency-stop mechanism.

## Session and movement policy

The app allows eye commands after handshake acceptance. An operator must confirm a visible eye change and separately enable movement. Confirmation resets on disconnection or session failure. Joint nudges also require a current layout reading through **Find connected joints** while movement is disabled. The picker offers only entries among the first eight logical slots that map to a detected servo; this is configuration evidence, not anatomical identification.

Commit `656a339` selected mode 2 before requesting a new full pose. A native hardware check then observed mode 4 after the `09` position read, strongly supporting a command-order fault in that nudge path. The implemented order is `09` read and freeze → `0B` mode 2 → `0A` confirm the selected slot reports mode 2 → `08` bounded target. Physical movement using the corrected order is not yet confirmed.

A complete fresh pose must arrive within the action timeout. Freezing that reply starts an absolute two-second monotonic baseline expiry. Mode selection, confirmation and every pose handoff must fit within it. The selected slot changes by at most three raw units; the other seven bytes are preserved. The selected current and target positions must be within 24–232. These are protocol bounds, not validated mechanical travel limits. Slot numbers have no assumed anatomical mapping.

The target is calculated once and refreshed with the identical packet at most ten times, spaced by at least 100 ms after each accepted write. Its deadline is the earlier of the one-second refresh limit and the frozen baseline's absolute two-second expiry. Only one pose write can be outstanding; delayed writes never cause a catch-up burst. Every pose packet, including a queued first packet, carries that deadline, checked by the transport immediately before handing it to CoreBluetooth. A stalled pose at expiry ends the session. After a normal finish, the controller allows 500 ms to settle and requests feedback before accepting another movement.

The bounded refresh was motivated by a timing difference found through static inspection of the original Android app: its nominal 50 ms scheduler writes poses on alternating enabled ticks, approximately 100 ms apart. That is decoded control flow, not a measured radio trace. A [community hardware report](https://github.com/chrisns/meccanoid/blob/929ab37efee7b2615e71dadd1589eaf53e72dcb1/docs/hardware-2026-09-18.md) also reports movement with sustained bounded updates on another robot. In this app's supervised test, ten identical frames requested UI slot 3 from 33 to 36 within one second; feedback remained 33 and the operator reported only a light flash. Repetition did not resolve the observed lack of movement on this robot.

The operator suggested that the nudge might be too small to see. That is an unconfirmed explanation; the available evidence does not establish that increasing the delta would resolve the joint-control failure.

The controller polls status once per second and treats more than five seconds without a valid reply as failure. Scan and handshake attempts also time out. Stop invalidates pending motion callbacks, cancels queued writes, disables movement and requests zero wheels and the stop preset. A write already handed to CoreBluetooth cannot be recalled. Backgrounding the app requests Stop when movement is enabled; it does not guarantee delivery after suspension.

The current stop path does not release servo torque, restore an earlier pose or establish which joint physically moved. Its effect still needs the [hardware pilot](hardware-pilot.md).

## Read-only mapping evidence: 2026-11-04

A separate follow-up diagnostic read configuration, logical mapping and mode replies without writing configuration, mapping or firmware. Configuration `02` detected servos at CH1A, CH1B, CH3A and CH4A, plus eyes at CH2A. Reply `03` contained all-zero data. The current logical map was `22 21 20 00 01 02 10 11`, followed by eight `FF` entries. Mode reply `0A` reported value 4 only at zero-based logical indices 2, 3 and 4 (UI slots 3, 4 and 5).

The map covers three of the four detected servos: CH4A is absent. This is a confirmed discrepancy, but UI slot 3 maps to the detected CH3A servo, so the missing CH4A entry alone is insufficient to explain that slot's failed movement test. The mode readback describes the state at the time of the diagnostic; it does not establish the cause of the earlier failure. The operator reports that onboard controls and voice commands move the robot's arms normally.

The diagnostic disconnected after these reads. No mapping, firmware or wiring change was made.

**Find connected joints** and **Read robot layout** under Connection details use the same diagnostic reading. It sends `02`, `03`, `20` and `0A` sequentially while movement is disabled, then displays detected modules, the first eight logical slots and any detected servos absent from the returned mapping. This reading is required before the joint picker offers configured servos. An eight-second timeout ends the session to prevent a late reply being mistaken for a new reading. No mapping or mode setter is sent by this feature.

Commit `656a339` passed package tests, a native Mac build and an unsigned iOS/iPadOS arm64 build. Its Mac practice interface displayed the simulated inventory, slots and mode codes while movement remained disabled. Its native layout interface was subsequently verified against the physical robot in the mode check below.

The corrected implementation has also passed package tests, a native Mac build and an unsigned iOS/iPadOS arm64 build. Its practice flow completed joint discovery, blue eyes and confirmation, movement enable, one joint-1 +3 nudge, feedback 128 → 131, and Stop with movement disabled. The demo models `09` resetting servo modes to 4. This validates the software flow against that model; it does not establish physical joint movement. The operator subsequently restarted and reconnected the robot for the corrected physical trial below.

## Native pose-read mode transition: 2026-11-04

With the operator-connected robot and movement disabled, native Mac app `656a339` ran `02 → 03 → 20 → 0A`. The layout showed mode 2 at zero-based logical indices 2, 3 and 4 (UI slots 3, 4 and 5). The app then sent only `09` through **Read position**. A second layout read showed unchanged configuration and mapping, but mode 4 at those same indices. No `0B` mode-setting or `08` target command was sent during this check, and no separate CLI control session completed.

The observed mode transition after `09` strongly supports the explanation that the old `0B → 09 → 08` sequence left the servos out of mode 2 before the target arrived. The correction moves the pose read before the mode-setting command and verifies mode 2 through `0A` before sending a target. It keeps the same ±3-unit delta and bounded refresh. The corrected sequence still needs physical movement confirmation.

## Corrected physical trial: 2026-11-04

After **Find connected joints** identified UI slot 3 as a configured servo, an operator-supervised +3 trial reported mode 2 for that slot before its position command. The app accepted target 33 → 36 and completed nine bounded refresh frames. The final position reply remained 33. Stop was clicked and movement was disabled in the app.

This confirms that the corrected sequence reached its mode-confirmation and target-submission stages. It does not establish that fixing the command order is sufficient to restore movement. The operator's visual report for this trial is pending, and no larger-delta comparison has been run.

## Status evidence

Status exposes the four chest-button bits, raw LED/current/battery codes, recording and preset counts, and an error code. Raw battery and current codes are not converted into volts, amperes or battery percentage because calibration is not established.

There are four distinct outcomes: a packet encodes correctly; Bluetooth accepts it; the robot sends a valid reply; an operator observes the intended physical effect. Tests and UI text must preserve these distinctions.
