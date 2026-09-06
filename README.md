# FreeFCC for iOS

iOS port of [FreeFCC USB](https://github.com/doesthings/FreeFCC-USB), the
open-source FCC unlock for DJI RC-N1 / RC-N2 / RC-N3 controllers. Same DUMPL
protocol, same 21-frame profile, same CRC tables. Different transport, because
iOS has no Android Open Accessory.

> **Disclaimer.** For educational and research purposes. Modifying radio
> transmission parameters may violate the law where you are: in most places,
> transmitting above the power permitted for your region requires authorisation
> from the regulator. You are solely responsible for compliance. Not affiliated
> with DJI, and using this may void your warranty and DJI Care Refresh.

> **Not tested on hardware.** Neither this port nor the Android original has
> been confirmed on a live aircraft. See [What is still unknown](#what-is-still-unknown).

## The one real difference: the transport

The Android build talks to the controller in **USB accessory mode (AOA)**: the
RC is the USB host, the phone is the accessory, `UsbManager.openAccessory()`
returns a file descriptor and raw DUMPL bytes go down it.

iOS has no AOA and no libusb. The only sanctioned link to a cabled accessory is
**MFi / ExternalAccessory**, which is exactly the channel DJI Fly itself uses on
iPhone: the controller is a certified accessory, the app opens an `EASession`
on one of its protocol strings and gets an `InputStream` / `OutputStream` pair.

Everything above that stream is unchanged:

| Layer | Android | iOS | Same? |
|---|---|---|---|
| DUMPL frame builder, CRC-8 + CRC-16 tables | `DumplBuilder.kt` | `DumplBuilder.swift` | byte for byte |
| RCLink envelope `55 CC 49 57 <len32>` | `wrapRclink` | `RCLink.wrap` | byte for byte |
| Bootstrap handshake, 2 frames | `sendBootstrap` | `Bootstrap.frames` | byte for byte |
| Keepalive pair every 2.5s | keepalive thread | run loop timer | byte for byte |
| 21-frame FCC profile, 2 rounds @ 30ms | `assets/profiles/fcc.json` | `Resources/profiles/fcc.json` | byte for byte |
| Sender sweep 0x82 then 0x02, then WLM | `applyFccInternal` | `applyFccSync` | same order |
| Transport | USB accessory (AOA) + USB VCOM | MFi `EASession` | **rewritten** |

Two things the port adds, both because the MFi channel is less well charted
than the AOA one:

- **A framing sweep.** The Android build always wraps in the RCLink envelope
  over AOA, and never wraps when plugged straight into the aircraft. Nobody has
  published which of the two the MFi command channel wants, so an apply can
  sweep both and the Log tab reports which one drew responses.
- **A real stream parser.** AOA reads arrive on packet boundaries; an MFi
  stream does not. `DumplStreamParser` resynchronises byte by byte and only
  emits frames whose header CRC-8 and body CRC-16 both check out, which is what
  makes the per-path response counts trustworthy.

## Build and install

Requirements: Xcode 26 or newer, iOS 17.0+ target, an Apple ID in Xcode.

```bash
brew install xcodegen           # once
cd FreeFCC-iOS
xcodegen generate
open FreeFCC.xcodeproj
```

Then pick your iPhone as the run destination and hit Run. The project signs
with the team wildcard profile, so no App Store Connect setup is needed.

```bash
# command line equivalents
xcodebuild -project FreeFCC.xcodeproj -scheme FreeFCC \
  -destination 'generic/platform=iOS' -configuration Release build
xcodebuild -project FreeFCC.xcodeproj -scheme FreeFCC \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

This build cannot go on the App Store: it opens a session on DJI's MFi protocol
strings without being part of DJI's MFi programme, and it changes a regulatory
radio setting. It is a sideload for your own hardware.

## Using it

1. Power on the aircraft and the controller, wait for the link.
2. **Close DJI Fly.** Swiping it away is enough on iOS in most cases; if the
   session will not open, force-quit it from the app switcher.
3. Cable the iPhone to the **TOP** USB port of the RC, the one in the phone
   cradle you normally use for DJI Fly. The bottom port is charging only.
4. Open FreeFCC, tap **Connect**. It keeps looking for 15 seconds, so you can
   tap it first and close DJI Fly afterwards.
5. Tap **Enable FCC Mode** and let the sweep finish.
6. Open the **Log** tab. A line like `profile@82/RCLink: 3 responses` names the
   path your hardware answered on. All paths at 0 means the controller is not
   relaying to the aircraft at all, which is a different failure from FCC being
   rejected.
7. Switch to DJI Fly and check the Transmission tab. Signal reaching past the
   1km mark is FCC, signal stopping at it is still CE.

FCC mode is RAM-only and reverts on a power cycle, so this has to be repeated
every time you power the aircraft up. The app re-applies on an interval for as
long as it holds the session, which also covers the two known resets: DJI Fly
reconnecting, and the aircraft dropping to CE when it sets the home point on
GPS lock.

The app declares the `external-accessory` background mode, so unlike on Android
it can keep the session and the repeat running while DJI Fly is in front. If
DJI Fly cannot see the controller anyway, tap **Release for DJI Fly** to hand
the link back without unplugging.

## If it says the protocol is not declared

iOS refuses an `EASession` for any protocol string not listed in
`UISupportedExternalAccessoryProtocols`. The app can still *read* the full list
the accessory advertises, so the Hardware card on the FCC tab shows every
protocol and flags the ones this build cannot open:

```
Protocol (open)    com.dji.protocol
Not declared       com.dji.something.else     <- amber
```

If the command channel turns out to be one of the amber ones, add it to
`FreeFCC/Info.plist` under `UISupportedExternalAccessoryProtocols` and rebuild.
The three strings shipped here are the ones DJI's own Mobile SDK requires on
iOS: `com.dji.protocol`, `com.dji.common`, `com.dji.video`.

## What is still unknown

Honest list of what has been verified and what has not.

**Verified here**

- The DUMPL frames this app builds are byte-identical to the Android build's,
  checked by recomputing both CRCs bitwise from their polynomials across every
  payload length from 0 to 64 bytes.
- The 21-frame profile still fits inside the service-mode window: one round is
  0.63s, well under the 1.5s the timing note calls for.
- The stream parser recovers frames from split reads, back-to-back frames,
  leading garbage, and RCLink envelopes, and rejects frames with a broken CRC.
- The app builds and signs for a real iPhone, and the 23 unit tests pass.

**Not verified, needs hardware**

- Whether the RC-N1/N2/N3 MFi channel accepts DUMPL commands at all. It carries
  DJI Fly's own command traffic, so the parser is on the other end of it, but
  no published capture confirms the framing.
- Which framing that channel wants, RCLink or raw. Hence the sweep.
- Which protocol string carries commands rather than video.
- Whether the aircraft actually switches region, which only the DJI Fly
  Transmission graph can tell you.

## Project layout

```
FreeFCC/
  Core/
    DumplBuilder.swift              frame builder, CRC-8 and CRC-16 tables
    RCLink.swift                    envelope, framing, incremental stream parser
    ProfileLoader.swift             JSON profile decoding
    DumplTransport.swift            transport protocol, bootstrap, keepalive
    ExternalAccessoryTransport.swift  MFi session, run loop IO thread
    FccController.swift             state, path sweep, repeat, CE restore
  App/
    FreeFCCApp.swift                entry point, EA connect notifications
    FccPage.swift                   main control surface
    LogPage.swift                   activity log, share sheet
    ProfilePage.swift               every frame the app will send, in hex
    AboutPage.swift                 how it works, disclaimer, credits
    DesignSystem.swift              palette and shared components
  Resources/profiles/               fcc.json, ce_restore.json
FreeFCCTests/                       23 tests over frames, parser, profiles
```

## License

AGPL-3.0, inherited from the upstream project. See [LICENSE](LICENSE) and
[NOTICE.md](NOTICE.md). The DUMPL protocol implementation derives from
[dji-firmware-tools](https://github.com/o-gs/dji-firmware-tools) (GPL-3.0).
