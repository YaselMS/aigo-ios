# AGENTS.md: Aigo for iPhone/iPad

Entry point for AI agents working on this repo. The product overview, plan, issues and working rules
live in the host repo `YaselMS/aigo` (private; locally `C:\Users\K\.code\.dev\aigo_v4`). Read its
`AGENTS.md`, `docs/STATUS.md` and `docs/ISSUES.md` first. Issue numbers below (#NN) refer to that
ISSUES.md. Code-level detail: [ios/README.md](ios/README.md).

## What this is

A native SwiftUI client (iOS 17+, iPhone and iPad) for the Aigo host daemon on a Windows PC. It pairs
once, then talks to the host API directly over TLS pinned to the PC's certificate, with a per-device
token. No Aigo account or server is involved. **Current version: v0.3.8** (2026-11-14), paired with
desktop host v0.4.0.

## Priorities (host north star, 2026-11-11)

Aigo is not a harness: the app continues and follows the user's real harnesses on their PCs.
Reliability over features. Work only in this order: 1 trustworthy terminal, 2 continue any session,
3 stay on top (needs you / done, one-tap answers, orchestrator asks), 4 reach outside the network,
5 screen view/control, 6 extensions. No new settings or looks until goals 1–3 pass the user's own
test on the real phone. Use proven parts (SwiftTerm) instead of home-made ones. Sub-agents run on
Opus (`model: opus`); resume a stopped agent with SendMessage instead of restarting it.

## Structure

```
ios/project.yml        XcodeGen spec (edit this; Aigo.xcodeproj and Config/*.plist are generated, git-ignored)
ios/Shared/            compiled into app + widget: activity attributes, intents, palette, fonts, mark
ios/Aigo/App/          entry, RootView, NotificationManager
ios/Aigo/Model/        Codable mirrors of host JSON, pairing link, status wording
ios/Aigo/Net/          PinnedSessionDelegate (cert pin), APIClient (REST), LiveSocket (WS + reconnect)
ios/Aigo/Store/        AppStore (single @MainActor source of truth), TranscriptModel, TerminalModel,
                       DesktopModel, HostVault (Keychain), AppearanceStore, UpdateChecker
ios/Aigo/Terminal/     TerminalSurface: SwiftTerm (SPM, pinned in project.yml) kept at the PTY size, gestures, palette
ios/Aigo/Views/        Home (board tabs), Session (Chat | Terminal | Changes), Desktop, NewWork, Search,
                       Pair, QR scanner, Settings
ios/AigoWidgets/       Live Activity / Dynamic Island
scripts/               package-ipa.sh, verify-ipa.sh
.github/workflows/ios.yml
```

## Build, CI and release

- Build needs a Mac (Xcode 16+, `brew install xcodegen`); commands are in [README.md](README.md). This
  repo is usually edited from Windows, so **CI is the build**: every push and PR to `main` runs lint →
  build on `macos-15` (Metal toolchain, XcodeGen, cached SPM resolve, unsigned archive) → package and verify the IPA → upload
  the artifact `Aigo-unsigned-ipa`.
- **Release:** bump `MARKETING_VERSION` in `ios/project.yml`, commit, push, then push a `v*` tag. The
  `release` job attaches `Aigo-unsigned.ipa` + `.sha256` to a GitHub Release (a tag containing `-` is a
  pre-release). Latest: https://github.com/YaselMS/aigo-ios/releases/latest/download/Aigo-unsigned.ipa
- CI fails on committed signing material (`.p12`, `.p8`, `.mobileprovision`, private keys). Never
  commit any. The app has no entitlements and no signing settings.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Don't rewrite pushed
  history.

## Sideloading (how the user installs)

The user signs the unsigned IPA with Signulous (or SideStore) and installs it. Consequences:
- no remote push (APNs needs a paid developer account): use the host's ntfy notifications instead;
- the Live Activity updates only while the app runs;
- Keychain can be unavailable on some setups, so `HostVault` falls back to a protected file;
- updates are manual: `UpdateChecker` polls the GitHub API (at most every 6 h) and shows the IPA link
  with Copy/Share (#74).

## Host API dependencies

Mirror the host's JSON exactly; the host's `docs/API.md` and `docs/ARCHITECTURE.md` §4 are the
contract. The app reads `host.capabilities` from the events snapshot only for `sessions.continue`
(Continue); otherwise it tolerates missing fields (e.g. the remote desktop monitor list).

| Feature | Endpoints | Host doc |
|---|---|---|
| Pairing | `POST /pairing/complete`; `aigo://pair?h=&a=&fp=&c=&n=` link; address failover from `remote.endpoints` | API.md §7 |
| Live state | `WS /events` (snapshot + `session.*`, `inbox.*`, `external.updated`, `board.updated`, `notify`) | ARCHITECTURE §1, API.md §1–§4 |
| Board, seen, search | session `board` fields, `POST /sessions/{id}/seen`, `/viewed`, `GET /search` | API.md §1–§5 |
| Continue (goal 2) | search items `harness`, `resumable`, `live`; `POST /continue` (409 `running_outside` → fork / watch), `POST /continue/watch`; capability `sessions.continue` (`Views/ContinueControl.swift`) | API.md §7j |
| Chat | `WS /sessions/{id}/transcript`, `WS /external/{key}/transcript`, `POST …/prompt`, `…/menu`, `POST /approvals/{id}` | API.md §5a (not yet §7h paging) |
| Terminal | `WS /sessions/{id}/attach?history=3000` (size + raw replay protocol, `hello.terminal`, `{"type":"report"}`), `…/input` (reports on older hosts), `…/keys`, `GET …/screen` | API.md §6 |
| Session control | `…/interrupt`, `…/kill`, `…/restart`, `DELETE /sessions/{id}` | ARCHITECTURE §4 |
| New work | `GET /agents`, `GET /recent-dirs`, `POST /sessions` | ARCHITECTURE §4 |
| Changes | `GET /git/status`, `GET /git/diff` | ARCHITECTURE §4 |
| Remote desktop | `GET /desktop/info`, `WS /desktop/stream` (info, monitors, control, cursor, frame time) | API.md §7d |

Not used yet (host has them; iPhone catch-up #66/#67): themes §7c, device looks §7e, sounds §7f,
usage §7g, transcript paging §7h, sent-by §7b, `POST /sessions/{id}/stop` (#77).

## Current features (v0.3.8)

Board as four tabs with counts; needs-you cards (swipe or Approve/Deny; destructive commands need a
second tap); conversation tabs Chat | Terminal | Changes; live terminal with direct typing, Ctrl latch,
hardware keys, pinch zoom, 5,000-line local scrollback (SwiftTerm since v0.3.6: mouse for TUIs, Ctrl/Alt bar, paste, selection copy); exited sessions viewable; remote desktop with
pinch/pan, trackpad mode, keyboard row, Picture settings sheet, view-only handling, fit above the keyboard;
New work; search with harness / running-where and Continue (goal 2); outside-Aigo sessions; several PCs with address failover (LAN, Tailscale); Live
Activity with Approve/Deny; mono fonts and text size; update notice.

## Built but not yet tested on a device

- v0.3.8: Continue (#95, goal 2): search and recent sessions show harness, project, activity and
  where it runs; Continue → `POST /continue` → the session's terminal; running in another window →
  host message, Continue a copy here, Notify me when it ends; Continue on outside-Aigo Working cards
  and the read-only view; no button on hosts without `sessions.continue`.
- v0.3.7: host v0.4.0 attach (#94): terminal reports as `{"type":"report"}` on the socket (REST on
  older hosts), raw VT replays written as they are; first tap in a mouse TUI focuses and clicks.
- v0.3.6: terminal is SwiftTerm (North star goal 1): herdr (mouse, two-finger wheel), gentle-shell / Pi,
  Codex, Claude Code; PC size / Fit to phone; pinch; paste; copy selection; exited read-only view.
- v0.3.5: #89 Picture settings stay open while the remote desktop stream updates.
- v0.3.4: #73 remote desktop above the keyboard, #78 direct terminal typing, #81 exited-session
  scroll/zoom, #82 full history, #74 update link (all P1 except #74, P2).
- v0.3.3: #63 remote desktop viewer. v0.3.2: #38 update notice, #39 Tailscale pairing / multi-address,
  #46 terminal size protocol, #6 hook-trust guidance.
- iPad full-screen layout (universal since v0.3.4).

## Next steps

1. **Now:** the user's real-device test of goals 1–3 with desktop v0.4.0 + iPhone v0.3.8 (host
   `docs/TESTING.md` §3): herdr from the phone; gentle-shell search → Continue → work; ntfy alerts.
   Fix what breaks; log non-major bugs in the host `docs/ISSUES.md`.
2. Goal 4 (reach outside the network): Tailscale-first pairing and errors, later a relay.
3. Goal 5: remote desktop items (#73, #75, #89); Game mode card (#84) later.
4. Waiting until goals 1–3 pass: generated Swift `Codable` models, iPhone catch-up (#66, #67:
   themes, sounds, device looks, usage), transcript paging (§7h), `stop`, #17, #18. Extension phone
   cards are goal 6.

## Rules for agents

- Never commit signing material; never add entitlements or push code without the user asking.
- Don't break older hosts: treat new host fields as optional.
- Follow the host repo's working and safety rules (AGENTS.md there): concise replies, log non-major
  bugs instead of fixing them during testing, one test at a time.
- Design follows the host's `docs/design/DIRECTION.md` (graphite / lime / coral / ice, Share Tech Mono,
  soft tinted buttons, sharp corners, buttons at least 40 px).
