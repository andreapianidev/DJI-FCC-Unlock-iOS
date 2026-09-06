# Notice

FreeFCC for iOS. Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com

Licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE).

## What this is

An original iOS application that switches a cabled DJI controller from CE to
FCC radio mode and sets the altitude ceiling to 500m. The whole app, the MFi
ExternalAccessory transport, the incremental stream parser, the multi-path
command sweep, the on-device diagnostics, and the discovery of the working
channel and country code on real hardware, is the author's own work.

## Protocol credit

The DUML/DUMPL command protocol the app speaks, including the CRC-8 and CRC-16
tables and the frame layout, is publicly documented by the
[dji-firmware-tools](https://github.com/o-gs/dji-firmware-tools) project
(GPL-3.0). This app implements that public protocol; it does not incorporate
DJI software. Two facts about the region and altitude mechanisms were verified
against that project's DUML dissector for this hardware:

- Country code `US` on the WiFi Set Country Code command is what moves the RC
  to FCC.
- `g_config.flying_limit.max_height`, written by its parameter hash, sets the
  altitude ceiling. The app writes 500.

## Not affiliated with DJI

This project is not affiliated with, endorsed by, or sponsored by DJI. "DJI",
"RC-N3", "DJI Fly" and drone model names are used only to describe
compatibility.
