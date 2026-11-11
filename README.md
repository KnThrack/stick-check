# Stick Check

A macOS app that measures a USB joystick and says whether it needs recalibrating. Written for a VKB Gladiator EVO, but it reads any HID joystick or gamepad.

macOS has no system-wide joystick calibration: games read the raw values the stick sends, and a VKB stick's calibration lives in its firmware. The app measures; for a VKB stick it can also run the stick's own calibration, which otherwise needs VKB's Windows-only VKBDevCfg.

The app listens to input reports. The "Read from stick" button and the `--vkb-info` and `--vkb-backup` commands send read requests that fetch a VKB stick's stored configuration. Two things change the stick: restoring a saved configuration (`--vkb-restore … --yes`, or "Restore previous" and "Abandon" in the calibration guide) and running its calibration ("Calibrate…" or `--vkb-calibrate`). Nothing here can send the protocol's other short commands (restart, factory defaults, bootloader).

## What it shows

- **Live:** every axis as raw counts and per cent, the range seen so far, X/Y and ministick pads with a trail, pressed buttons, the hat, and the report rate.
- **Stored on the stick** (VKB only, on request): which sensor slot feeds each axis, the calibration the stick holds for it (`Bias`, `KdLo`, `KdHi`), and the dead zones the firmware applies before the computer sees a value. A backup of the whole configuration can be saved from here, and "Calibrate…" runs the stick's own calibration with a guide: backup, Start, move every axis, Commit, then a before/after table with "Restore previous".
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

## Reading a VKB stick's configuration

```bash
swift run StickCheck --vkb-info
```

```bash
swift run StickCheck --vkb-backup
```

`--vkb-info` fetches the stick's 4096-byte configuration block, checks the stick's own checksum and prints the firmware version and the calibration stored for each physical axis (a zero offset `Bias` and two gains `KdLo`/`KdHi`). `--vkb-backup` also saves the block, read-only, to `~/Library/Application Support/Stick Check/Backups/`. The file is the raw block; it holds the per-unit calibration, so keep it out of git.

```bash
swift run StickCheck --vkb-restore "<backup file>"
```

`--vkb-restore` writes a saved block back to the stick's flash. As shown it is a dry run: it checks the file against the stick and lists the differences. Add `--yes` to write. Before sending anything it requires that the file passes its own checksum, matches the stick's device type and firmware, and that a fresh read of the stick decrypts correctly. The stick restarts after a write; the command waits for it and verifies that it holds exactly the file's contents.

```bash
swift run StickCheck --vkb-calibrate
```

`--vkb-calibrate` saves a backup, then walks through the stick's own calibration: Return sends "start", you move every axis through its full travel, Return sends "commit". The stick works out the new values itself, stores them and restarts; the command then lists what changed and prints the restore command for going back. It needs a terminal, since each step waits for Return.

What was learned doing this on a Gladiator EVO L at firmware 2.20.C:

- The stick ignores the calibration commands in plain form. It takes the encoded form: the four command bytes in the clear, the session token at offset 0x58 (counting the report ID), and bytes 5–124 RC4-encrypted with the four command bytes as the key. That is the default here; `--plain` sends the other.
- The stick does not acknowledge either command.
- On commit the stick restarts at once, so the transfer carrying the commit can come back as failed (IOReturn 0xE0005000, stalled pipe) although the commit was carried out.
- Only the calibration fields changed: `KdHi`, `KdLo` and `Bias` of the six sensor slots in use, plus the block checksum.

The protocol is not VKB-documented. It comes from the [vkbdevcfg-explained](https://github.com/brewer-corp/vkbdevcfg-explained) project (MIT), which worked it out from VKBDevCfg and verified reading and writing on a Gladiator EVO R at firmware 2.20.C. Reading, writing a block back unchanged, and the calibration commands are confirmed here on a Gladiator EVO L at the same firmware. The calibration commands were known to that project only from the vendor binary. The meaning of individual fields is theirs and only partly confirmed.

## Layout

- `Sources/StickCore` – the test as a pure state machine (`Session`) fed by commands, the analysis, and the read side of VKB's configuration protocol (`VKBLink`, `VKBBlock`). No IOKit, no UI; all the tests are here.
- `Sources/StickHID` – reads the stick through IOKit HID; `HIDFeatureTransport` carries the configuration frames.
- `Sources/StickCheck` – SwiftUI shell.

## Notes on the Gladiator EVO

- It reports X, Y, Rx, Ry as 0…4095 and Rz, Z as 0…2047, plus two unnamed axes, 128 buttons and one hat.
- It only sends a report when something changes, so the report rate is near zero at rest.
- The firmware applies its own dead zones (on this unit 3 % at the centre of X and Y, 10 % on twist and ministick). A centre reading of exactly 2048 therefore only shows the offset is inside that dead zone.
- Which physical control drives which axis depends on the profile loaded on the stick. Set each axis to *Self-centring* or *Slider* in the app before testing.
