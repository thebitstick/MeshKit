# AI disclosure

This project was built with AI assistance.

## What the AI did

Almost all of the code and documentation in this repository was written by **Claude** (Anthropic; Claude
Sonnet 5.5, run through Claude Code) in a back-and-forth session with the project's author:

- The app, `MeshKitCore`, the native ESP flasher, both protocol clients, the simulators, the tests, the build
  scripts and the documentation.
- The app icon, drawn by a script (`Scripts/make-icon.swift`) the AI wrote.
- Research into the protocols and release layouts of MeshCore and Meshtastic, and into the reference tools (`esptool`,
  the `meshtastic` CLI) the implementation was cross-checked against.
- Commits made with Claude's help carry a `Co-Authored-By: Claude` trailer.

Not AI-written: the Meshtastic protobuf Swift files (generated from Meshtastic's definitions) and Espressif's flasher
stubs (their published binaries).

## What the human did

The author decided what to build, directed the design, and ran the app against real hardware, reporting what worked and
what did not.

## What was tested

- `swift test`: about 110 tests against simulators of an ESP bootloader, a MeshCore companion and repeater, and a
  Meshtastic node, plus a pseudo-terminal test of the serial layer.
- The flasher's request stream was compared with the one `esptool` sends, and `esptool` and the `meshtastic` CLI were run
  against the simulators over TCP (`esp-sim`).
- `MESHKIT_NETWORK_TESTS=1 swift test` reads the newest MeshCore and Meshtastic (stable and alpha) releases and checks
  that every file is understood and that install images for a Heltec V3 and a Wio Tracker L1 can be built.
- GitHub Actions (`.github/workflows/check.yml`) builds, runs the tests and checks the app's code signature on a macOS runner; it passes.
- MeshCore's update and clean-install plans were checked against the real v1.17.1 images (partition layout, and that the application inside each merged image matches the app-only file) and against the simulated flasher (an update leaves the filesystem alone; a clean install erases it). They were then run on a real Heltec V3 with the repeater, companion and room server firmware.
- A real **Heltec V3** running MeshCore repeater, companion and room server (v1.17.1) and Meshtastic (stable and alpha): clean installs and updates, settings changes over USB, restoring a full flash backup, and connecting from the app. That testing found and fixed the repeater console parsing, slow `set` replies, clock-sync and slow-boot probe problems listed in the commit history.
- A **Wio Tracker L1** (nRF52840): MeshCore companion and Meshtastic installs over UF2, clean install with the erase tool, the OTAFIX bootloader update (OTAFIX 2.2 to 2.3, afterwards the board still booted), and Meshtastic's "enter DFU mode" request, which brought up the UF2 drive. The board-to-bootloader mapping is otherwise unchecked.

## What was not tested

- Other nRF52 boards, CH340 and native-USB ESP32 boards, and any chip other than the ESP32-S3 on the Heltec V3.
- Developer ID signing and notarisation (`SIGN_IDENTITY`, `NOTARY_PROFILE` in `Scripts/package.sh`).

## Caveats

- AI-written code can contain mistakes that look plausible. It has not had an independent human security review. The
  app writes firmware and settings to real devices; read the confirmation sheets and keep the automatic backups.
- Please report problems as issues. Pull requests are welcome, AI-assisted or not; please say which.
