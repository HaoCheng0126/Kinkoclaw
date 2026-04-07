# Repository Guidelines

- In chat replies, file references must be repo-root relative only (example: `apps/macos/Sources/KinkoClaw/KinkoClawApp.swift:12`); never absolute paths or `~/...`.
- Product scope is **KinkoClaw only**. This repo targets the macOS client and its bundled Live2D stage runtime. Do not reintroduce Android, iOS, Windows, or legacy OpenClaw app surfaces unless the user explicitly asks.

## Project Structure

- Native app shell: `apps/macos/Sources/KinkoClaw`
- Swift tests: `apps/macos/Tests/KinkoClawTests`
- Stage frontend runtime: `apps/macos/stage-live2d`
- Daily dev launcher: `scripts/run-kinkoclaw-debug.sh`
- Final `.app` packaging: `scripts/package-kinkoclaw-app.sh`
- App signing helper: `scripts/codesign-mac-app.sh`

## Build, Run, and Test

- Platform: macOS 15+
- Stage frontend build: `pnpm --dir apps/macos/stage-live2d build`
- Native build: `cd apps/macos && swift build --product KinkoClaw`
- Daily local run: `./scripts/run-kinkoclaw-debug.sh`
- Swift tests: `cd apps/macos && swift test --filter KinkoClawTests`
- Final packaging only: `./scripts/package-kinkoclaw-app.sh`

## Coding Guidelines

- Language split:
  - Swift / SwiftUI / AppKit in `apps/macos/Sources/KinkoClaw`
  - Vue + Vite + Pixi + Live2D runtime in `apps/macos/stage-live2d`
- Prefer strict, explicit types. Avoid `any`/loose payloads in new code when a closed shape is practical.
- Keep file references and runtime names aligned with `KinkoClaw`; do not add new product-facing `OpenClaw` app naming.
- Add brief comments only where behavior is non-obvious.
- Keep changes scoped. Do not mix UI polish, protocol refactors, and repo cleanup in one pass unless the user explicitly asked for all of them.

## Repository Hygiene

- Remove dead files when they no longer participate in KinkoClaw build, run, test, or packaging flows.
- Do not keep placeholder platform directories or unused legacy scripts.
- Build artifacts and local caches should stay out of tracked files.
- If you change startup flow, always revalidate the visible debug-binary path, not only the packaged `.app` path.
