<div align="center">

# 📡 Free FCC Unlock for iOS

### FCC unlock and 500m altitude for DJI RC-N1 / RC-N2 / RC-N3, native on iPhone

[![DJI FCC mode, unlocked from an iPhone. Free and open source.](docs/hero.jpg)](https://www.andreapiani.com/dji-fcc-unlock-ios.html)

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-iOS%2017%2B-black?style=flat-square&logo=apple)](#)
[![Confirmed](https://img.shields.io/badge/RC--N3%20%2B%20DJI%20Neo-confirmed%20on%20hardware-34D399?style=flat-square)](#-confirmed-on-hardware)
[![Website](https://img.shields.io/badge/Website-andreapiani.com-0A84FF?style=flat-square)](https://www.andreapiani.com/dji-fcc-unlock-ios.html)

**The first FCC unlock built natively for iPhone.** No server, no account, no
tracking. Everything runs on device.

An app by [Andrea Piani](https://www.andreapiani.com). Project page and FAQ:
[andreapiani.com/dji-fcc-unlock-ios](https://www.andreapiani.com/dji-fcc-unlock-ios.html).

</div>

---

> ## ⚠️ Disclaimer
>
> For educational and research purposes. Modifying radio transmission power or
> altitude limits may violate the law where you are. In most places,
> transmitting above the power permitted for your region, or flying above the
> permitted altitude, requires authorisation from the regulator. You are solely
> responsible for compliance. If you are not sure whether this is legal where you
> live, do not use it.
>
> Not affiliated with, endorsed by, or sponsored by DJI. Using this may void your
> warranty and DJI Care Refresh coverage.

---

## ✨ What it does

| | Feature |
|---|---|
| 📶 | **FCC unlock.** Switches the radio from CE to FCC: 33 dBm (about 2 W) instead of 20 dBm (about 100 mW) on 2.4 GHz, DJI's own limits for the RC-N3, for more channels and more range. |
| 🛰️ | **500m altitude.** Sets the flight-controller ceiling to 500m, DJI's own standard maximum. |
| 🔌 | **Native MFi.** Talks to the controller over the same certified channel DJI Fly uses, no jailbreak, no desktop, no second device. |
| 🔍 | **Readable.** Every byte sent is a plain JSON profile you can inspect on the Profile tab. |
| 🔒 | **Offline.** No server contact, no account, no tracking, ever. |
| 🔁 | **Auto-hold.** Re-applies while the app is backgrounded, so FCC survives DJI Fly reconnecting. |

## 📱 Screens

<table>
<tr>
<td align="center"><b>FCC active</b></td>
<td align="center"><b>Activity log</b></td>
<td align="center"><b>Command profile</b></td>
<td align="center"><b>About</b></td>
</tr>
<tr>
<td><img src="docs/screenshots/01-fcc.jpg" width="200" alt="FCC active"></td>
<td><img src="docs/screenshots/02-log.jpg" width="200" alt="Activity log"></td>
<td><img src="docs/screenshots/03-profile.jpg" width="200" alt="Command profile"></td>
<td><img src="docs/screenshots/04-about.jpg" width="200" alt="About"></td>
</tr>
</table>

<div align="center">
<img src="docs/screenshots/05-transmission.jpg" width="520" alt="DJI Fly transmission spectrum, clean 2.4GHz floor with FCC power active">
<br><sub>DJI Fly Transmission, 2.4GHz spectrum with FCC power active on an RC-N3 + DJI Neo</sub>
</div>

## ✅ Confirmed on hardware

Tested on real hardware, a **DJI RC-N3** controller cabled to an iPhone with a
**DJI Neo** aircraft: FCC power reached, verified on the DJI Fly Transmission
graph with the signal extending well past the 1km reference. Not a simulator or a
protocol mock, an actual controller and an actual drone in the air. Three things had to be right, and finding them was the work:

- 🔑 **The channel is `com.dji.logiclink`**, one of the two MFi protocol strings
  DJI does not publish. A build declaring only the three documented strings never
  sees the controller at all, because iOS hides an accessory whose protocols you
  did not declare. The string was read off the hardware.
- 🇺🇸 **The region is set by country code `US`.** The command is the WiFi Set
  Country Code the controller already accepts; the country it carries is what
  decides CE or FCC.
- 🔗 **The aircraft must be linked** when you apply, not just powered on. The
  frames reach the controller and stop there until it is relaying to a drone. The
  app shows a green link line with the aircraft serial once the drone is there.

One honest limit: this firmware answers no region-read command, so the app cannot
read the mode back. The DJI Fly Transmission graph is the confirmation.

## 🛠️ Build and install

Requirements: Xcode 26+, iOS 17+ target, an Apple ID in Xcode.

```bash
brew install xcodegen        # once
xcodegen generate
open FreeFCC.xcodeproj
```

Pick your iPhone as the destination and Run. The project signs with the team
wildcard profile, so no App Store Connect setup is needed. This is a sideload for
your own hardware, not an App Store build: it opens DJI's MFi protocol strings
and changes a regulatory radio setting.

## 🚀 Using it

The order matters. The controller only relays commands to the aircraft once
DJI Fly has woken that link, and the link stays warm for a while after DJI Fly
closes. That warm window is what the app needs.

1. Power on the **drone** and the controller, wait for them to pair.
2. **Open DJI Fly first** and wait until it shows the drone connected with a
   live camera feed. This is the step that wakes the controller-to-aircraft
   link. Skipping it is why an apply gets 0 responses even with the drone
   detected.
3. **Close DJI Fly** (swipe it away).
4. Cable the iPhone to the **TOP** USB port of the controller, the phone-cradle
   port.
5. Open FCC Unlock, tap **Connect**, wait for the green line with the aircraft
   serial, then tap **Enable FCC Mode** and let the sweep finish. A line like
   `profile@02/RCLink: 38 responses` means the aircraft answered.
6. Do **not** reopen DJI Fly straight away. Reopening it right after the unlock
   drops the radio back to CE every time (see the sequence below).

### Making FCC stick (confirmed on hardware, RC-N3 + DJI Neo)

Reopening DJI Fly immediately after the unlock loses FCC: DJI Fly renegotiates
the region on connect and the radio falls back to CE. The sequence that holds,
observed on hardware:

1. Start DJI Fly, let the drone link, then run the unlock in FCC Unlock
   (Connect, then Enable FCC Mode).
2. Close DJI Fly.
3. Power the **controller** off, then the **drone** off.
4. Power the controller back on, with the iPhone still cabled and FCC Unlock
   still holding the link.
5. Power the drone back on and let it relink.
6. Open DJI Fly, Transmission tab. FCC power is there and holds, matching the
   signal-graph screenshot in this repo.

FCC is RAM-based and the app re-applies on an interval while it holds the link,
which is what survives the power cycle here. If it ever reverts, repeat from
step 1.

> **Altitude, what the hardware actually reports.** The app writes the aircraft's
> `flying_limit.max_height` to 500 and the flight controller acknowledges it with
> status OK, but reading the value back the drone reports **120**, not 500: the
> `0xF9` reply carries `00 8A 23 71 03 78 00`, where `78 00` is 120. So the 120m
> ceiling is enforced drone-side too, not only inside DJI Fly, and `max_height`
> alone does not lift it. The parameter that actually governs a real 500m unlock
> is still being reverse engineered (issue #1). FCC **power** is a separate matter
> and works.

## 🧭 How it works

The app opens an `EASession` on the controller's MFi protocol and speaks the DUML
command protocol over the stream: it builds each frame with its CRC-8 and CRC-16,
wraps it in the link envelope, keeps the session alive with a keepalive, and
parses the aircraft's replies out of a stream that also carries the video feed.

Each apply sweeps several sender and framing combinations and counts the
responses, so the Log tab names the path your hardware answered on. The region is
set with the country code and the altitude ceiling with the flight controller's
`max_height` parameter, both inside one service-mode window.

> **Deep dive.** The full walkthrough, protocol and frames, transport, the
> service-mode window, the sweep, and every hardware finding is in
> **[docs/TECHNICAL-DOCUMENTATION.md](docs/TECHNICAL-DOCUMENTATION.md)** (English)
> or **[docs/DOCUMENTAZIONE-TECNICA.md](docs/DOCUMENTAZIONE-TECNICA.md)** (Italian).

## 📂 Project layout

```
FreeFCC/
  Core/    frame builder + CRC, link envelope + stream parser, profile loader,
           MFi transport, controller (sweep, hold, region, altitude, diagnostics)
  App/     SwiftUI screens and design system
  Resources/profiles/   fcc.json (FCC + 500m), ce_restore.json
FreeFCCTests/            frames, parser, profile and altitude checks
docs/TECHNICAL-DOCUMENTATION.md  full protocol + architecture writeup (English)
docs/DOCUMENTAZIONE-TECNICA.md   the same writeup in Italian
docs/screenshots/        the images above
```

## 🤝 Contributing, help wanted

This is the **open-source answer** to the paid FCC/altitude tools. FCC power is
done and confirmed; the rest is open reverse engineering, and it moves faster
with more hands and more hardware. Everything still to do is written up as
detailed issues:

- 🛰️ **[#1 Unlock 500m altitude](../../issues/1)** and **[#3 unlock ~60 km/h speed](../../issues/3)**, the headline features, both drone-side RE.
- 🔑 **[#2 Get the config-table read answering](../../issues/2)**, the tool that unblocks both of the above.
- ⚡ **[#4 Drop the "open DJI Fly first" step](../../issues/4)** by initialising the link ourselves.
- 🧪 **[#5 Testers wanted](../../issues/5)** on RC-N1 / RC-N2 and other aircraft, no coding needed, just a device and a log.
- 📡 **[#6 Read the region back](../../issues/6)** for a real in-app CE/FCC indicator.

Each issue lists what is known, the exact parameter hashes and commands, and the
next concrete step. Pick one, open a PR, or just run the app on your hardware and
post your log. Findings from real devices are as valuable as code.

> A write-up and a call for testers will go up on Reddit (r/dji and friends) so
> owners of other DJI gear can help map the parameters across models.

## 📜 License

GPL-3.0. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md). The DUML protocol the
app implements is publicly documented by the
[dji-firmware-tools](https://github.com/o-gs/dji-firmware-tools) project; the iOS
app and its logic are original work.

---

<div align="center">

© 2026 Andrea Piani · NIE Z2331796-S · Tijarafe, Santa Cruz de Tenerife · Islas Canarias

[andreapiani.com](https://www.andreapiani.com)

</div>
