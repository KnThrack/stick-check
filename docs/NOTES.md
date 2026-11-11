# Technical notes

## Code layout

- `Sources/StickCore` – the guided test as a pure state machine (`Session`) fed by commands, the analysis, VKB's configuration protocol (`VKBLink`, `VKBBlock`) and the restart logic (`RestartWatch`). No IOKit, no UI; all the tests are here.
- `Sources/StickHID` – reads the stick through IOKit HID; `HIDFeatureTransport` carries the configuration frames.
- `Sources/StickCheck` – the SwiftUI shell and the command-line options.

The verdict thresholds of the guided test are in `Settings` in [Session.swift](../Sources/StickCore/Session.swift).

## What talks to the stick

The app listens to input reports. Beyond that:

- **Read requests** are sent by "Read from stick", `--vkb-info` and `--vkb-backup`. They fetch the stored configuration and change nothing.
- **A configuration write** is sent by `--vkb-restore … --yes`, and by "Restore previous" and "Abandon" in the calibration guide.
- **The calibration commands** are sent by "Calibrate…" and `--vkb-calibrate`.

Nothing in the code can build the protocol's other short commands (restart, factory defaults, bootloader entry): the types only represent the three reads, one block write and the two calibration commands.

## Reading and restoring

`--vkb-info` fetches the stick's 4096-byte configuration block, checks the stick's own checksum and prints the firmware version, which sensor slot feeds each axis, and the calibration stored for each slot: a zero offset `Bias` and two gains `KdLo` and `KdHi`.

`--vkb-backup` also saves the block, write-protected, to `~/Library/Application Support/Stick Check/Backups/`. The file is the raw block. It holds per-unit calibration, so keep it out of version control. An identical backup is not saved twice.

`--vkb-restore <file>` is a dry run: it checks the file against the stick and lists the differences. With `--yes` it writes. Before sending anything it requires that:

- the file passes its own checksum;
- it matches the stick's device type and firmware version;
- a fresh read of the stick decrypts to exactly what was read a moment before, which proves the session key is right.

The stick restarts after a write. The command waits for it and verifies that it holds exactly the file's contents.

## Calibrating

The stick does its own calibration. The host sends "start", the user moves every axis through its full travel, the host sends "commit", and the stick works out the new values, stores them and restarts. `--vkb-calibrate` and the guide in the window both save a backup first and show what changed afterwards. The command-line version needs a terminal, because each step waits for Return.

An axis that is not moved during calibration may end up with a useless calibration.

## Where the protocol comes from

VKB does not document it. It was worked out from VKBDevCfg by the [vkbdevcfg-explained](https://github.com/brewer-corp/vkbdevcfg-explained) project, which verified reading and writing the configuration block on a Gladiator EVO R at firmware 2.20.C. The calibration commands were known to that project only from the vendor binary and had not been sent to a device. The meaning of the individual configuration fields is theirs and only partly confirmed.

## Confirmed here

On a Gladiator EVO L at firmware 2.20.C:

- Reading the configuration block, with the stick's own CRC-32 matching.
- Writing a block back unchanged, with the stick restarting and holding identical contents.
- The calibration commands:
  - The stick ignores them in plain form. It takes the encoded form: the four command bytes in the clear, the session token at offset 0x58 (counting the report ID), and bytes 5–124 RC4-encrypted with the four command bytes as the key. That is the default; `--plain` sends the other form.
  - The stick acknowledges neither command.
  - On commit the stick restarts at once, so the transfer carrying the commit can come back as failed (IOReturn 0xE0005000, a stalled pipe) although the commit was carried out.
  - Only the calibration fields change: `KdHi`, `KdLo` and `Bias` of the six sensor slots in use, plus the block checksum.
  - Two calibrations in a row gave values within a few counts of each other.

Not run on hardware: "Abandon" in the calibration guide, which writes the old configuration back while the stick is still measuring.

## Notes on the Gladiator EVO

- It reports X, Y, Rx and Ry as 0…4095 and Rz and Z as 0…2047, plus two unnamed axes, 128 buttons and one hat.
- It only sends a report when something changes, so the report rate is near zero at rest.
- The firmware applies its own dead zones before the computer sees a value (on the tested unit 3 % at the centre of X and Y, 10 % on twist and ministick). A centre reading of exactly 2048 therefore only shows that the offset is inside that dead zone.
- The ministick axes are set to find their centre at every start. Whatever position they are in when the stick is plugged in becomes their centre until it restarts.
- Which physical control drives which axis depends on the profile on the stick. Set each axis to *Self-centring* or *Slider* in the app before testing.

## Session token

The stick's session token is its microcontroller's unique ID, in effect a serial number. The code never prints or stores it.
