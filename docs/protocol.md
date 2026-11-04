# Protocol and implementation notes

These notes describe the current Swift implementation. The compatibility target is the original MeccaBrain's Bluetooth interface. This is separate from the serial Smart Module bus between the controller and individual servos.

The implementation follows community protocol research and independently checked packet facts. [Third-party notices](../THIRD_PARTY_NOTICES.md) identifies the sources. On 2026-11-04, an upstream native diagnostic produced operator-confirmed red eyes. A separate test of this SwiftUI Mac app then completed its own connection and produced operator-confirmed blue eyes on the same model 91763 MeccaBrain. Neither single-write nudges nor the bounded ten-frame refresh produced confirmed joint movement; the operator observed only a light flash and feedback stayed unchanged. See the [hardware evidence](hardware-pilot.md) for the distinction between submitted commands, replies and observed effects. iPhone/iPad hardware and physical stopping remain unverified.

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

Preset 8 is the stop entry reported for a community-tested G15KS firmware bank. Its meaning and effect are firmware-dependent. It is not a guaranteed emergency-stop mechanism.

## Session and movement policy

The app allows eye commands after handshake acceptance. An operator must confirm a visible eye change and separately enable movement. Confirmation resets on disconnection or session failure.

A joint nudge first selects mode 2, then requests a new full pose. A complete reply must arrive within the action timeout. The selected slot changes by at most three raw units; the other seven bytes are preserved. The selected current and target positions must be within 24–232. These are protocol bounds, not validated mechanical travel limits. Slot numbers have no assumed anatomical mapping.

The target is calculated once and refreshed with the identical packet at most ten times, spaced by at least 100 ms after each accepted write, within a one-second monotonic window. Only one pose write can be outstanding; delayed writes never cause a catch-up burst. Every pose packet carries the same expiry, checked by the transport immediately before handing it to CoreBluetooth. A stalled pose at expiry ends the session. After a normal finish, the controller allows 500 ms to settle and requests feedback before accepting another movement.

The bounded refresh was motivated by a timing difference found through static inspection of the original Android app: its nominal 50 ms scheduler writes poses on alternating enabled ticks, approximately 100 ms apart. That is decoded control flow, not a measured radio trace. A [community hardware report](https://github.com/chrisns/meccanoid/blob/929ab37efee7b2615e71dadd1589eaf53e72dcb1/docs/hardware-2026-09-18.md) also reports movement with sustained bounded updates on another robot. In this app's supervised test, ten identical frames requested UI slot 3 from 33 to 36 within one second; feedback remained 33 and the operator reported only a light flash. Repetition did not resolve the observed lack of movement on this robot.

The controller polls status once per second and treats more than five seconds without a valid reply as failure. Scan and handshake attempts also time out. Stop invalidates pending motion callbacks, cancels queued writes, disables movement and requests zero wheels and the stop preset. A write already handed to CoreBluetooth cannot be recalled. Backgrounding the app requests Stop when movement is enabled; it does not guarantee delivery after suspension.

The current stop path does not release servo torque, restore an earlier pose or establish which joint physically moved. Its effect still needs the [hardware pilot](hardware-pilot.md).

## Read-only mapping evidence: 2026-11-04

A separate follow-up diagnostic read configuration, logical mapping and mode replies without writing configuration, mapping or firmware. Configuration `02` detected servos at CH1A, CH1B, CH3A and CH4A, plus eyes at CH2A. Reply `03` contained all-zero data. The current logical map was `22 21 20 00 01 02 10 11`, followed by eight `FF` entries. Mode reply `0A` reported value 4 only at zero-based logical indices 2, 3 and 4 (UI slots 3, 4 and 5).

The map covers three of the four detected servos: CH4A is absent. This is a confirmed discrepancy, but UI slot 3 maps to the detected CH3A servo, so the missing CH4A entry alone is insufficient to explain that slot's failed movement test. The mode readback describes the state at the time of the diagnostic; it does not establish the cause of the earlier failure. The operator reports that onboard controls and voice commands move the robot's arms normally.

The diagnostic disconnected after these reads. No mapping, firmware or wiring change was made.

The app now implements **Read robot layout** under Connection details. It sends `02`, `03`, `20` and `0A` sequentially while movement is disabled, then displays detected modules, the first eight logical slots and any detected servos absent from the returned mapping. An eight-second timeout ends the session to prevent a late reply being mistaken for a new reading. No mapping or mode setter is sent by this feature.

The implementation passed 72 package tests, a native Mac build and an unsigned iOS/iPadOS arm64 build. The Mac practice interface displayed the simulated inventory, slots and mode codes while movement remained disabled. The native diagnostic interface has not yet been tested against the physical robot; the real-device evidence in this section came from the separate command-line diagnostic. The movement failure remains unresolved.

## Status evidence

Status exposes the four chest-button bits, raw LED/current/battery codes, recording and preset counts, and an error code. Raw battery and current codes are not converted into volts, amperes or battery percentage because calibration is not established.

There are four distinct outcomes: a packet encodes correctly; Bluetooth accepts it; the robot sends a valid reply; an operator observes the intended physical effect. Tests and UI text must preserve these distinctions.
