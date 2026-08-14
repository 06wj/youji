# YouJi AI Contributor Guide

This file is the working context for AI coding agents. Read it before changing the project. For the user-facing product description, read `README.md`; for the current data flow, read `docs/ARCHITECTURE.md`.

## Product

YouJi (游迹 · PlayLog) is a local-first iPhone game activity library for PlayStation and Nintendo Switch. It combines play time, recent activity, PlayStation trophies, cover art, filtering, and a copyable AI-analysis export.

The interface is Chinese-first. Prefer an official Chinese game title when a platform response provides one, then fall back to the platform's default title.

## Supported environment

- iOS 17+
- Swift 6
- SwiftUI, SwiftData, Swift Charts
- Xcode project: `YouJi.xcodeproj`
- Shared scheme: `YouJi`
- No third-party package dependencies
- Unit test target: `YouJiTests`

## Source map

| Path | Responsibility |
| --- | --- |
| `YouJi/Models/GameRecord.swift` | SwiftData model, platform identity, library visibility rule |
| `YouJi/Models/AIConversation.swift` | Persistent AI conversation, messages, and frozen game context |
| `YouJi/Services/ProductDataService.swift` | Versioned backup/restore, CSV, diagnostics, snapshot insights, reminders, and profile share cards |
| `YouJi/Services/SyncCoordinator.swift` | Only coordinator between views, platform clients, and persistence |
| `YouJi/Services/PlayStationAPIClient.swift` | PSN authorization, game pagination, localization, trophy fetching and caching |
| `YouJi/Services/NintendoOAuth.swift` | Nintendo PKCE authorization request and callback parsing |
| `YouJi/Services/NintendoAPIClient.swift` | Nintendo token exchange and play-activity mapping |
| `YouJi/Services/KeychainStore.swift` | Platform session and AI API-key storage |
| `YouJi/Services/AIAnalysisClient.swift` | Explicit AI game-profile and multi-turn chat requests |
| `YouJi/Services/AIPrompts.swift` | Shared game-brain context plus profile and chat prompt rules |
| `YouJi/Services/AISettingsStore.swift` | AI Keychain and model-name settings |
| `YouJi/Services/CoverImageStore.swift` | Persistent local cover cache and download deduplication |
| `YouJi/Views/DashboardView.swift` | Dashboard, platform tabs, sorting, lists, platform-specific sync buttons |
| `YouJi/Views/AIAnalysisView.swift` | Local filtering, preview, AI profile, and auxiliary clipboard copy |
| `YouJi/Views/AIChatListView.swift` | Persistent conversation list, creation, continuation, and deletion |
| `YouJi/Views/AIChatView.swift` | Multi-turn conversation view and automatic title generation |
| `YouJi/Views/SettingsView.swift` | User-owned AI API key and model configuration |
| `YouJi/Views/ProductViews.swift` | Game details, account archives, insights, plans, AI profile history, data management, and privacy UI |
| `YouJi/Views/Connect*View.swift` | Official platform web authorization UI |
| `YouJi/Design/Theme.swift` | Shared colors and visual styles |
| `YouJiTests/` | Account identity, date parsing, visibility, and snapshot regression tests |

## Product invariants

Preserve these behaviors unless the user explicitly changes the product requirements:

1. PlayStation and Switch can be viewed separately or together.
2. PS and NS have separate connect/sync buttons. Remote requests happen only after an explicit connect or sync action.
3. The library defaults to play-time descending, using recent play time as the tie-breaker. It also supports recent-play sorting.
4. PlayStation trophy sorting puts platinum games first, completion percentage second, then play time.
5. A platinum trophy receives a visible special marker.
6. Switch game rows do not show a trophy or completion progress bar. The Switch-specific summary is its recent seven-day activity.
7. Library views hide games with less than 60 minutes of play time when the last-played date is older than six months. This is a presentation rule only: never delete those records.
8. AI export reads the complete local SwiftData collection, including records hidden by the library rule. It must not trigger synchronization.
9. AI export filters by all/PS/Switch and strict minimum play time (`> 1h`, `> 2h`, `> 10h`, `> 50h`), previews cover thumbnails, and sorts by play time descending.
10. Exported text contains the game name, play time, and trophy ratio. Switch trophies are marked not applicable.
11. Cover art is stored locally after the first successful download and is excluded from iCloud backup.
12. AI analysis is never automatic on view appearance. It runs only after an explicit generate action and uses the current filtered result.
13. AI chat is never automatic. A new conversation snapshots all current-account games with strictly more than 60 minutes; every request includes that snapshot plus the current conversation, and requests happen only after the user sends a message.
14. AI conversations persist locally, can be created, continued, and deleted, and request a short title after the second AI reply.

## Data and identity rules

- `GameRecord.applicationID` is globally unique. Use `<platform>:<accountID>:<titleID>`; never merge records from different accounts.
- `PlaySnapshot` is append-only synchronization history. Store cumulative minutes and trophies for the current platform account after a completed sync.
- `GameRecord.totalMinutes` is the canonical duration unit. Convert only for display/export.
- Keep the seven-element `weeklyMinutes` array ordered oldest to newest according to the existing Nintendo mapping.
- Keep credentials and the user-provided AI API key in Keychain with `AfterFirstUnlockThisDeviceOnly`. Never put them in SwiftData, UserDefaults, source files, fixtures, screenshots, or logs.
- UserDefaults is only for non-sensitive display state such as nicknames, sync timestamps, and the cached PS trophy summary.
- Do not log authorization cookies, NPSSO values, OAuth codes, refresh tokens, Nintendo session tokens, or complete response bodies.
- Disconnecting an account removes its credential and display identity; it does not silently delete the user's local game history.

## Synchronization rules

- Views should call `SyncCoordinator`; they should not call platform API clients directly.
- Do not add background or automatic synchronization without explicit user approval.
- AI analysis must never receive platform credentials, account IDs, cover data, or unfiltered database contents. Only platform, title, total minutes, and trophy ratio from the visible export filter are allowed.
- Preserve PS two-stage persistence: save the full game list first, then fetch trophies serially and save each successful title immediately.
- Preserve PS trophy incremental caching: if `trophiesSyncedAt` is at or after `lastPlayedAt`, reuse the cached game trophy result. Failed or unmapped responses must not advance `trophiesSyncedAt`.
- Authentication failures including 401, 403, `invalid_grant`, and `invalid_token` invalidate the affected credential and require reconnection. Other failures should preserve local records and the other platform's session.
- Upserts must not remove games just because a platform response is partial or temporarily empty.
- The PlayStation and Nintendo endpoints used here are not stable public third-party APIs. Keep platform request/response compatibility changes inside the relevant client.

## UI rules

- Maintain a mobile-first SwiftUI layout and Dynamic Type-friendly text. Avoid fixed widths for primary text content.
- Use the existing YouJi theme and brand assets before adding new colors or images.
- Keep platform semantics consistent: blue/PS and red/NS.
- Platform-only UI belongs inside its platform view or conditional branch; do not show PS trophy concepts on Switch records.
- All user-facing copy should remain concise Simplified Chinese unless a product decision says otherwise.

## Build and verification

Run this non-signing simulator build after code or Xcode project changes:

```bash
xcodebuild \
  -project YouJi.xcodeproj \
  -scheme YouJi \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Also run the checks relevant to the change:

```bash
plutil -lint YouJi/Info.plist
find YouJi/Assets.xcassets -name Contents.json -exec jq -e . {} \;
git diff --check
```

Run unit tests on an available simulator:

```bash
xcodebuild \
  -project YouJi.xcodeproj \
  -scheme YouJi \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Authentication and live platform data require a physical iPhone and real accounts. Do not claim PSN or Nintendo sync is verified from a simulator-only build. When changing authorization, token exchange, headers, decoding, trophy mapping, or pagination, explicitly request or report the need for a real-device check.

## Change checklist

- Keep changes inside this repository; the parent `06wj` directory is a multi-project workspace.
- Do not commit signing team IDs, provisioning profiles, credentials, local SwiftData stores, DerivedData, or account screenshots.
- Update `README.md` when user-visible capabilities or setup steps change.
- Update `docs/ARCHITECTURE.md` when persistence, authentication, synchronization, or data flow changes.
- Update `CHANGELOG.md` for a release-worthy user-visible change.
- Preserve unrelated user changes and keep the working tree free of generated build products.
