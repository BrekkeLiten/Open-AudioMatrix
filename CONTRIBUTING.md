# Contributing to Open AudioMatrix

Thanks for helping out. Bug reports, ideas, docs fixes, and code are all welcome.

## Reporting bugs and requesting features

Open an issue using one of the forms. For bugs, include your Open AudioMatrix and macOS versions, the audio hardware involved, and steps to reproduce. Engine logs help a lot:

```bash
log show --last 10m --predicate 'subsystem == "io.github.brekkeliten.openaudiomatrix"'
```

## Development setup

You need macOS 15 or later and Xcode 16 (Swift 6).

```bash
swift build
swift test
swift run CoreSelfTest
swift run AudioMatrixApp      # matrix editor
swift run audiomatrix --help  # CLI
```

To try a packaged build, run `scripts/package-app.sh`. It produces an ad-hoc signed `dist/Open AudioMatrix.app`.

Capturing app audio needs the **System Audio Recording** permission (and **Microphone** for hardware inputs). macOS asks the first time. If routing stays silent, check System Settings → Privacy & Security.

## Sending a pull request

1. Fork the repo and create a branch from `main`.
2. Keep each PR focused on one change, and add or update tests where it makes sense.
3. Make sure `swift build` and `swift test` pass. CI runs both on every PR.
4. Describe what changed and how you tested it, including the hardware you used for audio changes.

## Code style

- Follow the style of the surrounding code.
- Use SwiftUI for UI. AppKit is only used where SwiftUI has no equivalent (see `.cursor/rules/no-appkit.mdc`).

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
