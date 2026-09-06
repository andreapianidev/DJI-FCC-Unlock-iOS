# Notice

This project is a derivative work of **FreeFCC USB** by doesthings,
<https://github.com/doesthings/FreeFCC-USB>, licensed under AGPL-3.0. It stays
under AGPL-3.0, and its source has to be offered to anyone it is distributed to.

The DUMPL protocol implementation in the upstream project derives from
[dji-firmware-tools](https://github.com/o-gs/dji-firmware-tools) (GPL-3.0).

## What was carried over unchanged

- The DUMPL wire format and both CRC tables, transcribed from
  `DumplBuilder.kt` and re-verified against the polynomials by the test suite.
- The RCLink envelope, the bootstrap handshake and the keepalive pair, from
  `DumplTransport.kt` and `FccViewModel.kt`.
- The `fcc.json` and `ce_restore.json` profiles. The frame data is byte for
  byte the upstream data. The only edit is in the human-readable `note` and
  `description` fields, where em dashes were replaced with commas to match the
  typography rules of this repository. No `s`, `i`, `d` or `p` value was
  touched.
- The apply strategy: sender sweep 0x82 then 0x02, the assistant unlock once
  per pass, the WLM 0x51/0x04 switch last, response counting per pass, and the
  repeat interval.
- The visual language of the Android UI: palette, card and button treatment,
  mode badge, connection pill.

## What is new in this port

- `ExternalAccessoryTransport`, an MFi `EASession` transport with a private run
  loop IO thread. Replaces both Android transports, since iOS has neither AOA
  nor raw USB access.
- `DumplStreamParser`, an incremental resynchronising parser. The Android RX
  path assumes each USB read starts on a frame boundary, which an MFi stream
  does not guarantee.
- The framing sweep, RCLink and raw, because which one the MFi command channel
  accepts is undocumented.
- Accessory diagnostics: advertised protocol strings, which are declared in
  Info.plist and which are not.
- The Profile tab, which renders every frame including its wire bytes.
- Swift Testing suites covering the builder, the parser and the profiles.
