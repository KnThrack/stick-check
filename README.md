# Stick Check

A macOS app that measures a USB joystick and tells you whether it needs recalibrating. For VKB sticks it can also read the configuration stored on the stick, back it up, and run the stick's built-in calibration, which otherwise needs VKB's Windows-only VKBDevCfg.

Stick Check is an independent project. It is not affiliated with or endorsed by VKB.

## What it does

- **Live view:** every axis as raw counts and per cent, the range seen so far, stick and ministick pads with a trail, buttons, hat and report rate.
- **Guided test** (about a minute): where each axis rests, whether it reaches both ends, and where it comes back to after release. Each axis gets a verdict of OK, Marginal or Needs recalibration, with the numbers behind it. The report can be copied or saved as Markdown.
- **VKB sticks:** shows the calibration and dead zones held in the stick's own memory, saves a backup of its configuration, restores one, and runs the stick's calibration with a step-by-step guide.

macOS has no system-wide joystick calibration: games read the raw values a stick sends. So a stick that is off has to be fixed on the stick itself, which is what the VKB part is for.

## Requirements

- macOS 14 or later
- A Swift 6 toolchain (Xcode 16 or later). Built and tested with Xcode 27.

No third-party dependencies.

## Build and run

```bash
swift run -c release StickCheck
```

```bash
./make-app.sh
```

The second command builds `build/Stick Check.app`, which you can double-click. Run the tests with `swift test`.

Command-line options, all for VKB sticks except the first:

| Option | What it does |
|---|---|
| `--dump` | Prints what the app sees of each connected stick |
| `--vkb-info` | Reads the stick's configuration and prints its calibration |
| `--vkb-backup` | The same, and saves the configuration to `~/Library/Application Support/Stick Check/Backups/` |
| `--vkb-restore <file>` | Compares a backup with the stick; with `--yes`, writes it back |
| `--vkb-calibrate` | Runs the stick's calibration, step by step |

## Tested hardware

One stick: a VKB Gladiator EVO L at firmware 2.20.C. That is the only device the VKB features have been run on.

The measuring part uses standard HID and should work with any joystick or gamepad, but it has only been run with that stick. Reports from other hardware are welcome.

## Safety

- Measuring and reading change nothing on the stick.
- **Restoring and calibrating rewrite the stick's stored configuration.** Before calibrating, the app saves a backup and can write it back.
- VKB does not document the protocol used here. On hardware or firmware other than the one tested, a write could leave a stick misconfigured, and recovering it may need VKB's own tool on Windows.
- The app cannot send the commands that reset a stick to factory defaults or put it into its bootloader.

Use it on your own hardware and at your own risk. There is no warranty; see the licence.

## How it works

The measurement logic is a pure Swift state machine with no I/O (`Sources/StickCore`), read through IOKit HID (`Sources/StickHID`) and shown by a thin SwiftUI shell (`Sources/StickCheck`). Details of the VKB protocol, what was confirmed on hardware and what was not are in [docs/NOTES.md](docs/NOTES.md).

## Credits

The VKB configuration protocol was worked out by the [vkbdevcfg-explained](https://github.com/brewer-corp/vkbdevcfg-explained) project (MIT). Stick Check implements it independently from that project's documentation and adds a hardware confirmation of the calibration commands.

VKB and VKBsim are trademarks of their respective owners.

## Licence

[MIT](LICENSE)
