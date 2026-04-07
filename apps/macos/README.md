# KinkoClaw macOS app

## Quick dev run

```bash
./scripts/run-kinkoclaw-debug.sh
```

This is the only supported daily development run path.
It rebuilds the stage frontend, rebuilds the `KinkoClaw` Swift target, stops old instances, and launches the visible debug binary directly.

## Packaging flow

```bash
./scripts/package-kinkoclaw-app.sh
```

Creates `dist/KinkoClaw.app` and signs it via `scripts/codesign-mac-app.sh`.

## Signing behavior

Auto-selects identity (first match):
1) Developer ID Application
2) Apple Distribution
3) Apple Development
4) first available identity

If none found:
- errors by default
- set `ALLOW_ADHOC_SIGNING=1` or `SIGN_IDENTITY="-"` to ad-hoc sign

## Team ID audit (Sparkle mismatch guard)

After signing, we read the app bundle Team ID and compare every Mach-O inside the app.
If any embedded binary has a different Team ID, signing fails.

Useful env flags:

- `SIGN_IDENTITY="Apple Development: Your Name (TEAMID)"`
- `ALLOW_ADHOC_SIGNING=1`
- `CODESIGN_TIMESTAMP=off`
