<p align="center">
  <img src="Resources/icon-readme.png" width="128" height="128" alt="MeshKit icon">
</p>

<h1 align="center">MeshKit</h1>

<p align="center">
  Install, back up and configure <b>MeshCore</b> and <b>Meshtastic</b> radios from your Mac, over USB.
</p>

<p align="center">
  <img src="Resources/screenshot-welcome.png" width="300" alt="Welcome window">
  <img src="Resources/screenshot-firmware.png" width="480" alt="Firmware window">
</p>

> Unofficial, and largely AI-written (see [AI-DISCLOSURE.md](AI-DISCLOSURE.md)). Not affiliated with the MeshCore or
> Meshtastic projects.

---

MeshKit has a window for each project, **MeshCore** and **Meshtastic**, opened from the Welcome window or the Window
menu. The ESP32 flasher is written in Swift, so there's no `esptool`, Python or browser involved.

## Features

| | MeshCore | Meshtastic |
|---|---|---|
| **Firmware** | Companion, repeater and room server releases, plus builds from other GitHub projects you add | Stable and Alpha releases |
| **Install** | ESP32 over serial. nRF52 over USB (no drive or reset button) or the UF2 drive. **Update** keeps settings and identity; **Clean install** erases | Same |
| **Configure** | Companion (USB) and repeater / room server: name, location, radio, routing, adverts | Names, region, modem preset, hop limit, TX power, role |
| **Convert** | Switch a board between MeshCore and Meshtastic, carrying its name and location across | Same |
| **Back up** | Settings snapshots, full ESP32 flash images, nRF52 firmware images; restore any of them | Same |

- **Backups are labelled** with the firmware inside ("MeshCore v1.17.1 (d929643)"), so you restore the one you mean.
- **Works offline.** Release lists and downloaded firmware are kept for 30 days.
- **Updates itself** (Sparkle). Turn it off in Settings ▸ Updates.
- Any `.bin` or `.uf2` can be flashed from File ▸ Flash Image from File (⌘O). Demo devices (Help menu) let you try
  everything without hardware.
- On nRF52 boards the three-dot menu can install the OTAFIX bootloader, which makes Bluetooth firmware updates more
  reliable.

## Install

Download the zip or DMG from Releases and drag **MeshKit.app** into Applications. It isn't notarised, so on first launch
Control-click it and choose **Open**. macOS may also ask to let it read removable volumes: that is the board's drive.

To build from source (Swift 6 toolchain, macOS 14+):

```sh
./Scripts/build-app.sh      # build/MeshKit.app
./Scripts/package.sh        # universal build, plus a zip and DMG in build/release
swift test
```

## Hardware

| Chip | Install | Tested on |
|---|---|---|
| ESP32, S2, **S3**, C2, C3, C6, H2 | Serial | **Heltec V3**: Meshtastic, MeshCore companion, repeater and room server; Update, Clean install, backup and restore, Convert |
| nRF52840 | USB, or UF2 drive | **Wio Tracker L1** and **Heltec T096**: installs, clean install, restore, Convert, OTAFIX bootloader |
| ESP32-P4, RP2040 / RP2350, STM32 | | Not supported |

Other boards with these chips should work but haven't been tried; reports are welcome.

## Safety

- ESP32 installs first save the whole flash to `~/Library/Application Support/MeshKit/FlashBackups` (this can be turned
  off in Settings). **Backups ▸ Restore** writes one back. These files contain keys and Wi-Fi settings, so keep them
  private; Settings ▸ Backups can delete them all.
- Installing over USB can't back up an nRF52 board first. Use Backups ▸ Back up (it needs the board's drive) if you want one.
- Images for the wrong chip, or larger than the flash, are refused before anything is erased.
- Firmware from other projects is shown with a warning: MeshKit can't vouch for it.
- MeshKit only reads from the network: GitHub (firmware), `api.meshtastic.org` and `api.meshcore.nz`.
- Radio frequency and power limits depend on where you are. Choosing a region or preset is your responsibility.

## Troubleshooting

- **No board listed:** use a data cable, close anything else using the port, and replug.
- **Can't enter the bootloader (ESP32):** hold **BOOT**, tap **RESET**, release BOOT, and try again. If a write fails
  partway, lower the speed to 115,200 in the install sheet.
- **An nRF52 won't install over USB:** MeshKit offers the board's drive instead. Double-tap **reset** quickly so it appears.
- **"No … firmware answered":** the board needs MeshCore USB companion, repeater or room server firmware, or Meshtastic
  firmware, matching the window you connected from.
- The **Log** tab shows every command and reply; "Copy for Bug Report" adds the app and macOS versions.

## License

GPL-3.0 ([LICENSE.md](LICENSE.md)), because it links Meshtastic's GPL-3.0 protobuf definitions. Other components are
listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Names and trademarks belong to their owners.
