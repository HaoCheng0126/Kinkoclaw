# KinkoClaw

English | [简体中文](README.zh-CN.md)

KinkoClaw is a macOS desktop pet client for an existing OpenClaw Gateway.
It turns your deployed or locally running OpenClaw into a menu bar companion with a floating pet, an AIRI-style Live2D stage, and a lightweight chat shell.

## What It Does

- Menu bar app that stays out of the Dock
- Floating desktop pet with click-to-open stage
- AIRI-inspired Live2D stage with character view on the left and chat on the right
- Connect to an existing OpenClaw Gateway over:
  - Local `ws://127.0.0.1`
  - SSH tunnel
  - Direct `wss://`
- Bind the UI to the `main` session of your gateway
- Import and switch Live2D model packs
- Adjust scene framing, scale, and offsets
- Keep a local persona memory card that shapes replies before sending them

## Product Shape

KinkoClaw is intentionally a thin client.
It does not install, host, or manage OpenClaw for you.
You run OpenClaw somewhere else, and KinkoClaw acts like the desktop shell you use to talk to it.

## Current Experience

- `macOS` only
- Menu bar entry plus floating desktop pet
- AIRI-style stage runtime embedded with `WKWebView`
- Live2D rendering for both the stage and the pet shell
- Debug text chat panel kept as a fallback tool

## Main Features

### Connection

- Local gateway connection
- Remote gateway connection through SSH tunnel
- Direct remote `wss://` connection
- Connection settings stored locally in the app

### Character Stage

- Large Live2D character stage
- Subtitle bubble and chat history
- Settings drawer inside the stage
- Character switching and imported model packs
- Scene framing controls for scale and offsets

### Desktop Pet

- Floating pet overlay
- Click to open the main stage
- Drag to reposition
- Position persistence between launches

### Persona Memory Card

- Local character identity
- Speaking style
- Relationship to the user
- Long-term memories
- Constraints

The memory card is applied locally before messages are sent, so it influences replies without writing back to the gateway.

## Repository Layout

- `apps/macos/Sources/KinkoClaw`: native macOS app shell
- `apps/macos/stage-live2d`: AIRI-style stage frontend runtime
- `apps/macos/Tests/KinkoClawTests`: focused macOS client tests
- `scripts/package-kinkoclaw-app.sh`: app bundle packaging helper

## Running From Source

### Prerequisites

- macOS 15+
- Xcode
- Node.js
- pnpm

### Build the stage frontend

```bash
cd apps/macos/stage-live2d
pnpm install
pnpm build
```

### Build the macOS app

```bash
cd apps/macos
swift build --product KinkoClaw
```

### Run the app

```bash
cd apps/macos
./.build/arm64-apple-macosx/arm64-apple-macosx/debug/KinkoClaw
```

## Packaging

To build a standalone app bundle:

```bash
./scripts/package-kinkoclaw-app.sh
```

## Notes

- KinkoClaw depends on an existing OpenClaw Gateway, but this repository is focused on the client experience.
- The main product work currently lives in the macOS client and the Live2D stage runtime.

## License

MIT
