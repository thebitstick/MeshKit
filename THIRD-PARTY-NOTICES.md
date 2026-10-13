# Third-party notices

MeshKit is GPL-3.0 ([LICENSE.md](LICENSE.md)). It includes or depends on the following.

## Included in the app

| Component | License | Where |
|---|---|---|
| **Meshtastic protobuf bindings**, generated from https://github.com/meshtastic/protobufs (commit `95c5f8c`) | GPL-3.0 | `Sources/MeshtasticProtobufs/` (see its `NOTICE.md` and `LICENSE-GPL-3.0`) |
| **esp-flasher-stub v1.3.0** (Espressif), the RAM-resident flasher programs uploaded to ESP chips | Apache-2.0 or MIT | `Sources/MeshKitCore/Resources/Stubs/` (license files alongside) |
| **swift-protobuf** (Apple) | Apache-2.0 | Swift package dependency |

The protobuf bindings are why MeshKit as a whole is GPL-3.0.

## Used as a reference only (no code included)

- **esptool** (Espressif), GPL-2.0-or-later: its source and behaviour were used as a reference for the ESP serial
  bootloader protocol, and the real tool is run against MeshKit's simulator in the test workflow. MeshKit contains no esptool code.
- **Meshtastic firmware** (`AdminModule.cpp`), GPL-3.0: read to confirm admin-message rules. No code included.
- **MeshCore** (MIT), https://github.com/meshcore-dev/MeshCore: its documented companion protocol and CLI are implemented
  independently. No code included.

## Data fetched at run time

- Firmware from the GitHub releases of MeshCore (MIT) and Meshtastic (GPL-3.0). Nothing is redistributed with MeshKit.
- The OTAFIX bootloader update files from the GitHub releases of `oltaco/Adafruit_nRF52_Bootloader_OTAFIX` (a fork of the MIT-licensed Adafruit nRF52 bootloader), only when the user chooses to download or install one. Nothing is redistributed with MeshKit.
- Board names from `api.meshtastic.org`, and radio presets from the community list at `api.meshcore.nz`.

## Trademarks

Meshtastic, MeshCore, ESP32, Espressif, Heltec, LilyGo, Seeed, RAK and other names are the property of
their owners and are used only to say what MeshKit works with. MeshKit is not affiliated with or endorsed by them.
