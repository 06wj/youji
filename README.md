<p align="center">
  <img src="YouJi/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png" width="112" alt="YouJi app icon">
</p>

<p align="center">
  English · <a href="README_ZH.md">简体中文</a>
</p>

<h1 align="center">YouJi</h1>

<p align="center">
  <strong>Your game brain</strong>
</p>

<p align="center">
  Turn your PlayStation and Nintendo Switch history into a personal library that understands you.
</p>

YouJi organizes the games you have actually played, the time you invested, and the trophies you earned. Its AI builds on that history to reveal your tastes and habits—and to help you choose the next adventure worth starting.

## Screenshots

<p align="center">
  <strong>Game Brain</strong>
</p>

<p align="center">
  <img src="docs/screenshots/export.jpg" width="32%" alt="Generate a gaming profile by platform and depth of play">
  <img src="docs/screenshots/ai-chat.jpg" width="32%" alt="Get replay recommendations grounded in your own game history">
</p>

<p align="center">
  <strong>Local Game Library</strong>
</p>

<p align="center">
  <img src="docs/screenshots/overview.jpg" width="23%" alt="YouJi overview">
  <img src="docs/screenshots/playstation.jpg" width="23%" alt="PlayStation games and trophies">
  <img src="docs/screenshots/switch.jpg" width="23%" alt="Nintendo Switch seven-day activity">
</p>

## It understands your history, not just your genres

### Discover your gaming personality

Use the games you genuinely invested in to uncover your core preferences, depth of engagement, and appetite for challenge. Choose a platform and scope so each analysis answers what matters to you right now.

### Talk to an AI that already knows what you play

No spreadsheets, pasted lists, or repeated explanations. Ask why Soulslikes resonate with you, which game deserves another playthrough, or what to start next. YouJi answers from your own history and keeps the conversation coherent as you follow up.

### Keep the conversations worth returning to

Chats are saved locally and organized into easy-to-find topics. Continue an existing conversation, start a new one, or delete anything you no longer need.

## A console history that is truly yours

- **One cross-platform library:** See PlayStation and Nintendo Switch games, play time, totals, and recent activity in one place.
- **Trophies and platinums:** Revisit PlayStation trophy progress, completion rates, and every platinum you worked for.
- **Recent activity:** Understand your Nintendo Switch rhythm through a focused seven-day view.
- **A cleaner collection:** Keep meaningful games in focus while short trials and long-forgotten launches stay out of the way.
- **Built for the long term:** Sync when you choose, keep your covers and history on device, and let the library grow with you.

## Get started in three steps

1. Connect your PlayStation or Nintendo Account.
2. Sync your activity to build a cross-platform game library.
3. Open Game Brain to generate a profile or talk through what to play next.

AI features use your own model configuration, which you can add in Settings the first time you use them.

## Your data stays under your control

- Game records and conversations are stored locally first.
- YouJi contacts platform or AI services only after an action you initiate.
- Account credentials and your AI API key are protected by the system and never become part of your game library or this repository.
- The AI receives only the information needed for the analysis or conversation, never your platform credentials.

---

## Development

### Requirements

- iOS 17+
- Xcode 26 recommended
- Swift 6

### Build and run

1. Clone the repository and open `YouJi.xcodeproj`.
2. Select your development team under **Signing & Capabilities**.
3. When installing on a physical device, use a Bundle Identifier available to your Apple Developer account.
4. Select the `YouJi` scheme and run.

```bash
xcodebuild \
  -project YouJi.xcodeproj \
  -scheme YouJi \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build
```

The simulator is suitable for exploring the interface. Connecting real PlayStation and Nintendo accounts requires a physical device.

### Stack

- SwiftUI for the interface
- SwiftData for game records, sync snapshots, and AI conversations
- Swift Charts for Nintendo Switch activity
- AuthenticationServices and WebKit for platform sign-in
- Keychain Services for platform sessions and the user-provided AI API key
- URLSession for platform sync and AI requests
- CryptoKit for cover-cache filenames

Cover images are cached under `Application Support/YouJi/Covers`. Platform sessions use the `AfterFirstUnlockThisDeviceOnly` Keychain accessibility level.

### Project structure

```text
YouJi/
├── Assets.xcassets/       # App icon and brand assets
├── Design/                # Theme and shared view styling
├── Models/                # SwiftData game, snapshot, and conversation models
├── Services/              # Platform sync, AI, Keychain, and cover caching
├── Views/                 # Dashboard, sign-in, Game Brain, chat, and settings
└── YouJiApp.swift         # App entry point

docs/
├── ARCHITECTURE.md        # Data flow, storage, and sync design
└── screenshots/           # README screenshots with metadata removed

YouJiTests/                # Model, parsing, prompt, and persistence regression tests
```

See the [architecture notes](docs/ARCHITECTURE.md) for the current data flow and platform sync design. Before making AI-assisted changes, read the [AI contributor guide](AGENTS.md) for product invariants, security boundaries, and verification steps.

### Platform API notes

The PlayStation and Nintendo activity endpoints used by this project are not stable public third-party APIs. When platform behavior changes, start with:

- `YouJi/Services/PlayStationAPIClient.swift`
- `YouJi/Services/NintendoAPIClient.swift`

## Disclaimer

This is an independent project for personal use and learning. It is not affiliated with Sony Interactive Entertainment or Nintendo. PlayStation, PS4, PS5, Nintendo Switch, and related marks belong to their respective owners.

## License

YouJi is available under the [MIT License](LICENSE).
