<!--
SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
Copyright (C) 2026 Andrea Piani. https://www.andreapiani.com
-->

# Contributing

FCC power works and is confirmed on one pair of devices. Everything past that is
open reverse engineering against a protocol nobody documents, on firmware that
changes under us. That is not a solo job, so here is how to help in a way that
actually lands.

## The most valuable thing you can send is a log

Not code. A log.

Five of the open issues are blocked on hardware nobody here owns. A single log
from an RC-N1, or from an aircraft that is not a Neo, is worth more to this
project than a refactor, because it answers a question that cannot be answered
by reading the source.

Use the [hardware report form](../../issues/new?template=hardware-report.yml).
It asks for exactly what is needed and nothing else.

**The part people leave out:** connect, wait 10 to 15 seconds, then tap
**Dump All Traffic** on the FCC tab and include what it prints. The automatic log
only says `Census has N distinct frame kinds`. That line is a count, not the
census. The census itself is what tells us which addresses your flight controller
actually answers on, and it is usually where the answer is hiding.

**Always remove your aircraft serial** before posting. It is on the
`Aircraft detected:` line.

## You do not need a Mac

Every push builds an unsigned `.ipa`. Grab it from the
[latest release](../../releases/latest), or from a green run of the
[Build workflow](../../actions/workflows/build.yml) if you want the newest commit.

It is unsigned, so iOS will refuse it as it comes. Re-sign it with your own Apple
ID through [Sideloadly](https://sideloadly.io) or [AltStore](https://altstore.io),
both of which run on Windows and Linux as well as macOS. A free Apple ID lasts 7
days, a paid developer account a year.

If the workflow fails on your fork, open an issue with the job log instead of
patching around it locally. It is meant to work for everyone.

## If you do want to write code

```bash
brew install xcodegen
xcodegen generate
open FreeFCC.xcodeproj
```

Requirements: Xcode 26+, iOS 17 target, Swift 6 with strict concurrency on. The
unit suite runs on any iPhone simulator and must stay green:

```bash
xcodebuild test -project FreeFCC.xcodeproj -scheme FreeFCC \
  -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
```

House rules, in order of how much trouble they save:

- **Never claim a result you did not measure.** This whole repo turns on telling
  "the drone refused" apart from "the frame never arrived". If you did not see it
  on hardware, write that you did not.
- **A write that is not read back is not a result.** A DUML ack means the frame
  was accepted, not that the value stuck. `max_height` is acked at 500 and stored
  at 120, which is exactly the trap this rule exists for.
- Keep the Experimental tab's colour contract: green reads, amber writes limits,
  red writes flight-control parameters.
- New probes go on Experimental, behind their own button, with the log lines that
  make the result readable by someone who is not you.

## Safety, and the line this project does not cross

Some parameters here affect how the aircraft flies. Anything that changes
attitude limits or control response is flight-test territory, and the person
doing that test is putting their own drone and other people's safety on the line.

- Do not send a PR that widens a flight-control limit you have not flown behind.
- Do not report a speed or altitude result from a graph alone. Fly it, record it,
  post the recording.
- If a change could make an aircraft less recoverable, say so in the PR in plain
  words, at the top, not in a comment three files down.

Radio power and altitude limits are regulated where you live. The project takes
no position on what you do with that; it does insist that nobody is misled about
what a change actually does.

## License

PolyForm Noncommercial 1.0.0. Free for noncommercial use, and it is deliberately
not an OSI licence: the point is that the paid tools cannot simply absorb this
work and resell it. By opening a PR you agree your contribution ships under the
same terms, with attribution.
