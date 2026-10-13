# CLAUDE.md

Guidance for Claude (or any contributor) working in this repository.

## What this is

MeshKit: a native macOS SwiftUI app (macOS 14+, SwiftPM, Swift 6 toolchain in Swift 5 language mode) that installs,
backs up and configures MeshCore and Meshtastic LoRa radios over USB. GPL-3.0 (set by the Meshtastic protobuf
bindings it links). The code is AI-written; keep `AI-DISCLOSURE.md` truthful when that changes. Bundle ID
`rip.bitstick.MeshKit`.

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/MeshKit/` | the SwiftUI app: `MeshKitApp.swift` (scenes, menus, Welcome, toolbar tabs), `AppModel.swift`, views |
| `Sources/MeshKitCore/` | everything that is not UI, and what the tests cover |
| `Sources/MeshKitCore/ESP/` | native ESP bootloader protocol: SLIP, loader, stub, flasher, simulator |
| `Sources/MeshKitCore/Companion/`, `Repeater/` | MeshCore companion binary protocol and repeater CLI |
| `Sources/MeshKitCore/Meshtastic/` | stream-API client, release catalogue, remote zip reader, simulator |
| `Sources/MeshKitCore/Firmware/` | MeshCore releases, UF2, flasher abstraction |
| `Sources/MeshKitCore/Resources/Stubs/` | Espressif flasher stubs (Apache-2.0 / MIT) |
| `Sources/MeshtasticProtobufs/` | generated from Meshtastic's protobufs; never edit by hand |
| `Sources/ESPSim/` | `esp-sim`: serves the simulated ESP or Meshtastic node over TCP for reference tools |
| `Tests/MeshKitCoreTests/` | the tests |
| `Resources/` | `Info.plist`, `AppIcon.icns`, README images |
| `Scripts/` | `build-app.sh`, `package.sh`, `make-icon.swift` |

Layout conventions follow the author's other macOS apps (MDKit, TimeScreen): output in `build/`, `Resources/`,
`Scripts/build-app.sh`.

## Commands

```
swift build
swift test                                    # ~110 tests, ~10 s, no hardware or network
MESHKIT_NETWORK_TESTS=1 swift test            # also runs the live-release tests (newest MeshCore and Meshtastic)
Scripts/build-app.sh                          # build/MeshKit.app, release, host arch, ad-hoc signed
UNIVERSAL=1 Scripts/build-app.sh              # arm64 + x86_64
Scripts/package.sh                            # universal build, then build/release/*.zip, *.dmg, SHA256SUMS.txt
swift Scripts/make-icon.swift Resources       # redraws AppIcon.icns and icon-readme.png
MESHKIT_HARDWARE_PORT=/dev/cu.usbserial-0001 MESHKIT_HARDWARE_STEP=read swift test --filter HardwareTests  # real Heltec V3 repeater; steps: read, write, update, clean, restore:<file>, catalog, set:<key>=<value>
swift run esp-sim --port 5555 --chip esp32s3  # simulated ESP for esptool: esptool --port socket://127.0.0.1:5555 chip_id
swift run esp-sim --meshtastic --port 4403    # simulated node for: meshtastic --host 127.0.0.1 --info
```

- Dev launch switches (any of them skips the Welcome window): `--vendor=meshcore|meshtastic`,
  `--section=firmware|configure|backups|log`, `--demo=companion|repeater|meshtastic`, `--select=<board>`,
  `--role=Companion|Repeater|…`, `--flash-file=<path>`. `MESHKIT_DUMP_MENU=1` prints the main menu.
- Screenshots: `screencapture -x -o -l <windowID>` with an ID from `CGWindowListCopyWindowInfo`. It captures a black
  frame when the display is locked.
- A running app keeps state in `~/Library/Application Support/MeshKit` and `~/Library/Caches/MeshKit`. Tests use
  temporary directories; do not point them at the real ones.

## Design decisions to preserve

- **One `AppModel` per device window**, each tied to a vendor (`FirmwareVendor`). The window only probes its own
  firmware, so a Meshtastic node in the MeshCore window is a clear error rather than a guess. Closing a window
  disconnects so the port is free. Windows: Welcome (always the launch window), MeshCore, Meshtastic. State
  restoration is off on purpose: `ApplePersistenceIgnoreState` is registered, windows are `isRestorable = false`, and
  device windows are resized and re-centred on every open (`WindowPlacer`). Without this macOS reopens the last window
  and skips Welcome.
- **Native flasher, no esptool.** Packets are SLIP-framed; the command checksum seed is 0xEF; after the stub is
  running it talks the stub dialect. Pre-flight checks refuse an image for the wrong chip or larger than the flash
  before anything is erased. A flash backup is taken first unless the user turns it off.
- **Meshtastic channels come from GitHub's prerelease flag, not the release title.** Titles say "Alpha"/"Beta" but
  non-prerelease builds are what Meshtastic recommends.
- **Meshtastic install plans:** update writes the app at 0x10000; a clean install erases, then writes the factory image
  at 0x0, the OTA loader at the second app partition and the filesystem, offsets read from the board's `.mt.json`.
  Files are fetched by HTTP range from the per-platform zip; never download the whole archive.
- **MeshCore install types:** published MeshCore ESP32 images are a 64 KiB header (bootloader, partition table at
  0x8000, otadata at 0xE000) followed by the app at 0x10000, identical to the app-only file. *Update* writes otadata
  plus the app, read out of the merged image after parsing its partition table, so nvs and the filesystem (identity,
  settings) survive; resetting otadata makes the bootloader pick app0 even after an OTA. *Clean install* erases and
  writes the merged image at 0x0. Only the merged image is downloaded. nRF52 UF2 has no erase of its own: a *Clean install* there first copies Meshtastic's `Meshtastic_nRF52_factory_erase_v3_S140_<7.3.0|6.1.0>.uf2` (read by range from a Meshtastic release's nrf52840 zip; MeshCore uses the latest stable Meshtastic release) to the bootloader drive, waits for the drive to come back, then copies the firmware. The file is chosen from the `SoftDevice:` line of `INFO_UF2.TXT`; if that is missing or unknown the clean install refuses.
- **DFU bootloader fix (nRF52):** the three-dot menu offers the OTAFIX bootloader (`oltaco/Adafruit_nRF52_Bootloader_OTAFIX`,
  recommended by MeshCore's FAQ). Per-board `update-<board>_bootloader-…_nosd.uf2` files are copied to the UF2 drive like
  firmware; their UF2 family is `0xD663823C`, not nRF52840, so `UF2VolumeFlasher(content: .bootloaderUpdate)` checks for
  that family instead. Board slugs from MeshCore and Meshtastic map to OTAFIX board ids in `OTAFix.swift`; only boards
  with a confident match get the menu items, because the wrong bootloader can brick a board.
- **Meshtastic admin writes** go to our own node, reliable, with `from == 0`; the session key is only enforced for
  packets with `from != 0`; a managed node ignores local admin, and the app says so.
- **Release data is untrusted.** Tag and asset names go through `ReleaseClient.safeComponent` before touching a
  path; URLs built from tags never force-unwrap. Radio presets from the network are validated (`isValid`) because
  they end up written to radios.
- **`Commands` do not observe `@Observable`**, so menu state goes through `ObservationBridge`. Menu commands act on
  the focused window's model (`FocusedValue`).
- Secrets: snapshots never include private keys or passwords. Flash images do include them; the README says so.
- The first launch of an unsigned app needs Control-click ▸ Open; the zip is built so its signature survives a plain
  `unzip` (no AppleDouble files). `package.sh` verifies that.

## Upstream facts (verified)

- MeshCore companion USB framing: `<` app to radio, `>` radio to app, 16-bit LE length. BLE has no envelope. The
  repeater CLI answers with a line prefixed `->` or `>` and has no end-of-reply marker; MeshKit waits for quiet.
  Four companion commands are marked `UNVERIFIED` in `CompanionProtocol.swift`; confirm them against firmware before
  claiming support.
- Meshtastic stream API: `0x94 0xC3`, big-endian 16-bit length, protobuf. Waking a node takes a run of `0xC3`.
- MeshCore releases are per role, tagged `companion-vX`, `repeater-vX`, `room-server-vX`. Companion builds come in `usb`
  and `ble` variants; repeaters and room servers have one build per board.
- Real v1.17.1 repeater console (Heltec V3, checked on hardware): `get x` answers `  -> > value`; `ver` and `board` answer
  `  -> value`; a `set` is echoed at once and answered `OK` up to a second later (flash write), so an echo alone is not a
  reply; the serial console sets the clock with `time <epoch>` (`clock sync` returns `ERR: clock cannot go backwards`);
  `advert.interval` takes 0 (off) or 60-240; a freshly erased board takes several seconds to boot and prints
  `Repeater ID: …` before the console answers.
- Radio presets come from `api.meshcore.nz`, cached 24 hours, with a bundled snapshot as the offline fallback.

## Working agreements

- **Ask before outward or irreversible actions:** pushing, publishing a release, committing in someone else's
  repo, deleting data. Approval for one does not carry to the next.
- **Never touch the user's uncommitted work.** Do not `git stash`, `reset` or `checkout` to compare things.
- **Be honest about verification.** Say what was tested and what was not. Only the Heltec V3 (Meshtastic including a
  clean install, MeshCore companion and repeater) has run on real hardware; say so rather than implying more.
  Not tried on hardware: nRF52 UF2 installs, CH340 and native-USB ESP32 boards, the
  Developer ID signing and notarisation path.
- **No comments unless the code is not self-explanatory.** Comment only a non-obvious *why* (a protocol quirk, a
  SwiftUI workaround), never what the code already says.
- **Keep documentation short.** One README, this file, `AI-DISCLOSURE.md`, `THIRD-PARTY-NOTICES.md`. No `docs/`
  folder, changelog or contributing guide; the author does not want them.
- **Public repo hygiene:** no personal data (names, hostnames, IPs, emails, keys, serial numbers) in tracked files.
- **Clean up** scratch files, simulators and background processes you start, and say what you touched when asked.
- Commits made with Claude's help end with the `Co-Authored-By` trailer; the user is the author.

## Shell gotchas

- The user's shell is Nushell. Wrap anything with globs or POSIX syntax in `bash -c '…'`, for example
  `bash -c 'grep -rn foo Sources'`. Prefer the dedicated search tools.
- macOS bash is 3.2: no empty-array expansion under `set -u`. `Scripts/build-app.sh` uses `${A[@]+"${A[@]}"}`.
- Extended attributes on the built app turn into `._*` files in a zip and break the signature; scripts run
  `xattr -cr` before signing and `ditto --norsrc --noextattr --noqtn` to zip.
- Running UI checks from a shell: AppKit only applies menu changes while the app is active, so a menu dump from a
  background launch can show stale enabled states.
- `swift build` caches heavily; a "Build complete" in two seconds after an edit is normal. Rebuild with
  `Scripts/build-app.sh` before screenshotting, and `pkill -x MeshKit` first.
