# termonmac

Mac CLI daemon for [TermOnMac](https://termonmac.com) — remote terminal access to your Mac from iPhone and iPad.

This is the open-source Mac-side component. It runs a terminal session on your Mac and relays it to the [TermOnMac iOS app](https://apps.apple.com/app/id6759218342) through an end-to-end encrypted channel.

## Install

```bash
brew install termonmac/tap/termonmac
```

## Build from source

Requires macOS 13+ and Swift 5.9+.

```bash
git clone https://github.com/termonmac/termonmac.git
cd termonmac
swift build -c release
# Binary at .build/release/termonmac
```

## Usage

```bash
termonmac          # Interactive setup wizard on first run
termonmac help     # Show all commands
```

On first run, `termonmac` generates a device identity key, displays a QR code, and waits for the iOS app to scan it. Once paired, the connection is automatic.

## Architecture

```
iPhone / iPad                    Relay (Cloudflare DO)                  Your Mac
┌──────────┐     E2E encrypted     ┌──────────┐     E2E encrypted     ┌──────────┐
│ iOS App  │ ◄──────────────────► │  Relay   │ ◄──────────────────► │ termonmac│
└──────────┘   (AES-256-GCM)      └──────────┘   (AES-256-GCM)      └──────────┘
                                   Sees only                          PTY session
                                   ciphertext                         management
```

- **Pairing**: QR code → X25519 ECDH key exchange → mutual authentication
- **Encryption**: Curve25519 + AES-256-GCM with forward secrecy (ephemeral keys per session)
- **Relay**: Zero-knowledge — the relay routes encrypted blobs and cannot read terminal content
- **Terminal**: Native PTY via `forkpty()`, login shell, full ANSI support

See [SECURITY.md](SECURITY.md) for the threat model.

## Source layout

```
Sources/
├── MacAgent/        CLI entry point, TUI, setup wizard
├── MacAgentLib/     Core logic: relay connection, PTY, device trust
├── RemoteDevCore/   Shared protocol layer (also used by iOS app)
├── BuildKit/        Xcode build integration
├── CPosixHelpers/   C helpers for PTY operations
└── CEditline/       GNU editline wrapper for interactive CLI
Tests/
├── MacAgentTests/   22 test files — agent, IPC, trust, PTY
├── RemoteDevCoreTests/  Crypto, WebSocket, protocol tests
└── BuildKitTests/   Build pipeline tests
```

## Configuration

Config lives in `~/.config/termonmac/`:

| File | Purpose |
|------|---------|
| `config.json` | Settings (relay URL, shell path, etc.) |
| `identity_key` | Ed25519 device identity (mode 0600) |
| `trust_store.json` | Enrolled iOS device public keys |
| `room.json` | Room credentials (mode 0600) |

Override the relay server for development:

```bash
RELAY_SERVER_URL=wss://your-relay.example.com termonmac
```

## Tests

```bash
swift test
```

## License

[MIT](LICENSE) — Chun-Pai Yang

## Links

- [termonmac.com](https://termonmac.com) — Product page
- [Engineering notes](https://termonmac.com/blog) — 33+ deep dives into the implementation
- [Homebrew tap](https://github.com/termonmac/homebrew-tap) — Formula source
- [How it works](https://termonmac.com/how-it-works) — Full architecture walkthrough
