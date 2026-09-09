# Notice

FreeFCC for iOS. Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com

Required Notice: Copyright (C) 2026 Andrea Piani (https://www.andreapiani.com)

Licensed under the **PolyForm Noncommercial License 1.0.0**. See [LICENSE](LICENSE).

## License in plain words

This project is free and its source is open to read, use, study and build on,
**for noncommercial purposes only**. That means personal use, research,
experiments, hobby projects, education, and use by nonprofit, public or
government bodies. All of that is allowed and encouraged.

**What is not allowed:** any commercial use. You may not sell this software, sell
a product or service built on it, use it to make money, or use it to promote or
advertise a commercial offering. If you want a commercial license, ask the author
at https://www.andreapiani.com; commercial licensing is granted separately and at
the author's discretion.

## Attribution is mandatory

Whoever receives any part of this software, in source or built form, modified or
not, must keep this notice and the `Required Notice:` line intact, and must keep
the copyright and license visible. The in-app About screen shows the author and
license and must not be stripped or replaced.

You may not present this work, or a modified version of it, as your own. Passing
this project off as your own work, in a repository, a forum, a video, a store
listing, a portfolio or anywhere else, is a breach of this license and an
infringement of copyright, on top of being untrue: the app, its MFi transport,
its stream parser, its command sweep and every hardware finding are the original
work of Andrea Piani.

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
(GPL-3.0). A network protocol and the mathematical CRC constants that describe
it are facts, not copyrightable expression: this app implements that public
protocol from scratch and does not incorporate any code from that project or any
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
