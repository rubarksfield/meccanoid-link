# Protocol and implementation notes

These notes describe the current Swift implementation. The compatibility target is the original MeccaBrain's Bluetooth interface. This is separate from the serial Smart Module bus between the controller and individual servos.

The implementation follows community protocol research and independently checked packet facts. [Third-party notices](../THIRD_PARTY_NOTICES.md) identifies the sources. On 2026-11-04, a separate upstream native diagnostic completed the handshake, received status and eight-slot pose replies, and produced operator-confirmed red eyes on an original MeccaBrain. [That diagnostic evidence](hardware-pilot.md#diagnostic-evidence-2026-11-04) supports the protocol path on one robot. The SwiftUI app and its own CoreBluetooth transport still await physical validation; no movement was commanded during the diagnostic.

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
| `08` | Set complete pose | Eight raw positions followed by nine `01` bytes |
| `09` | Read pose | Zero-filled; reply positions are bytes 1–8 |
| `0B` | Servo mode | Sixteen `02` bytes for control, or sixteen `04` bytes for read mode; final byte zero |
| `0D` | Wheels | Left direction, right direction, left magnitude, right magnitude, `FF FF`, then zeros |
| `11` | Eyes | `00 00`, `(green << 3) \| red`, blue, then zeros; each channel 0–7 |
| `19` | Stop preset request | `08 00`, then zeros |
| `1A` | PIN handshake | `01 00 01`, then zeros |

Wheel direction codes are `01` for requested forward and `02` for requested reverse; zero-wheel frames use `02` with magnitude zero. The codec accepts signed raw magnitudes up to 100. The interactive controller further limits them to 40 and schedules zero-speed after 250 ms. These values are not percentages or calibrated speeds.

Preset 8 is the stop entry reported for a community-tested G15KS firmware bank. Its meaning and effect are firmware-dependent. It is not a guaranteed emergency-stop mechanism.

## Session and movement policy

The app allows eye commands after handshake acceptance. An operator must confirm a visible eye change and separately enable movement. Confirmation resets on disconnection or session failure.

A joint nudge first selects mode 2, then requests a new full pose. A complete reply must arrive within the action timeout. The selected slot changes by at most three raw units; the other seven bytes are preserved. The selected current and target positions must be within 24–232. These are protocol bounds, not validated mechanical travel limits. Slot numbers have no assumed anatomical mapping.

The controller polls status once per second and treats more than five seconds without a valid reply as failure. Scan and handshake attempts also time out. Stop invalidates pending motion callbacks, cancels queued writes, disables movement and requests zero wheels and the stop preset. A write already handed to CoreBluetooth cannot be recalled. Backgrounding the app requests Stop when movement is enabled; it does not guarantee delivery after suspension.

The current stop path does not release servo torque, restore an earlier pose or establish which joint physically moved. Its effect still needs the [hardware pilot](hardware-pilot.md).

## Status evidence

Status exposes the four chest-button bits, raw LED/current/battery codes, recording and preset counts, and an error code. Raw battery and current codes are not converted into volts, amperes or battery percentage because calibration is not established.

There are four distinct outcomes: a packet encodes correctly; Bluetooth accepts it; the robot sends a valid reply; an operator observes the intended physical effect. Tests and UI text must preserve these distinctions.
