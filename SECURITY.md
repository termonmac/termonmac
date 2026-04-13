# Security & Threat Model

TermOnMac routes terminal I/O between your Mac and your iPhone through a relay server. This document explains what each component can and cannot see.

## Cryptographic primitives

| Layer | Primitive | Purpose |
|-------|-----------|---------|
| Pairing | X25519 ECDH | Establish shared secret via QR code |
| Device identity | Ed25519 | Sign and verify device public keys |
| Session encryption | AES-256-GCM | Encrypt all terminal traffic |
| Key derivation | HKDF-SHA256 | Derive per-session keys from ECDH output |
| Forward secrecy | Ephemeral X25519 | New key pair per connection, old keys discarded |
| Channel binding | HMAC-SHA256 | Bind session to specific device pair |

All crypto uses Apple CryptoKit (hardware-backed where available). No third-party crypto libraries.

## What each component can see

### Your Mac (`termonmac` daemon)

- **Full access** to your terminal session (it *is* the terminal)
- Device identity private key (stored in `~/.config/termonmac/identity_key`, file mode 0600)
- Plaintext terminal input and output
- All files and commands your shell can access

This is why this code is open source — you can audit exactly what runs on your machine.

### The relay server

- **Cannot see** terminal content (receives only AES-256-GCM ciphertext)
- **Cannot see** which commands you run or what output you receive
- **Can see** connection metadata: when you connect, connection duration, data volume (byte counts), your IP address
- **Can see** your account ID and device pairing topology (which devices are paired)
- **Cannot decrypt** traffic even if compelled — it never possesses the session keys

### The iOS app

- Same access as your Mac side — it holds the other half of the session key and sees plaintext terminal content
- Device identity private key (stored in iOS Keychain)

## What happens if the relay is compromised

An attacker who fully controls the relay server:

1. **Cannot read** any past or current terminal sessions (no key material on relay)
2. **Cannot inject** commands — messages are authenticated with AES-GCM; tampered ciphertext fails decryption
3. **Can deny service** — drop or delay connections
4. **Can observe metadata** — connection timing, data volume, IP addresses
5. **Cannot perform MITM on new pairings** — pairing uses a QR code scanned in physical proximity; the shared secret is established out-of-band

In short: a compromised relay is a *availability* threat, not a *confidentiality* or *integrity* threat.

## Credential storage

| File | Protection |
|------|-----------|
| `~/.config/termonmac/identity_key` | File mode 0600, Ed25519 private key |
| `~/.config/termonmac/room.json` | File mode 0600, room auth credentials |
| `~/.config/termonmac/trust_store.json` | Public keys of enrolled iOS devices |
| `~/.config/termonmac/api_key.txt` | Relay API authentication token |

No credentials are embedded in the binary or transmitted in logs.

## Reporting vulnerabilities

If you find a security issue, please email [quietlight.work@gmail.com](mailto:quietlight.work@gmail.com) with details. We will acknowledge within 48 hours and work on a fix before public disclosure.
