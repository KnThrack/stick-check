# Stick Check

A macOS app that measures a USB joystick and says whether it needs recalibrating. Written for a VKB Gladiator EVO, but it reads any HID joystick or gamepad.

It is a measuring tool, not a calibrator. macOS has no system-wide joystick calibration: games read the raw values the stick sends, and a VKB stick's calibration lives in its firmware, written by VKB's Windows-only VKBDevCfg. Stick Check only listens to input reports and never writes to the device.

## What it shows

- **Live:** every axis as raw counts and per cent, the range seen so far, X/Y and ministick pads with a trail, pressed buttons, the hat, and the report rate.
- **Guided test** (about a minute):
  1. *Hands off* – where each axis rests and how much it jitters.
  2. *Full travel* – whether each axis reaches both ends of its range.
  3. *Release* – where self-centring axes come back to after being let go, from each side.
- **Result per axis:** OK, Marginal or Needs recalibration, with the numbers behind it and the smallest dead zone that hides what was measured. The report can be copied or saved as Markdown.

Thresholds are in `Settings` in [Session.swift](Sources/StickCore/Session.swift).

## Build and run

```bash
swift run -c release StickCheck
```

```bash
./make-app.sh
```

The second builds `build/Stick Check.app`, which can be double-clicked. `StickCheck --dump` prints what the app sees of each connected stick and exits.

```bash
swift test
```

## Layout

- `Sources/StickCore` – the test as a pure state machine (`Session`) fed by commands, and the analysis. No IOKit, no UI; all the tests are here.
- `Sources/StickHID` – reads the stick through IOKit HID.
- `Sources/StickCheck` – SwiftUI shell.

## Notes on the Gladiator EVO

- It reports X, Y, Rx, Ry as 0…4095 and Rz, Z as 0…2047, plus two unnamed axes, 128 buttons and one hat.
- It only sends a report when something changes, so the report rate is near zero at rest.
- Which physical control drives which axis depends on the profile loaded on the stick. Set each axis to *Self-centring* or *Slider* in the app before testing.
