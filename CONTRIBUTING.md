# Contributing to PrivateSecretary

Thanks for helping improve the project.

PrivateSecretary is a **local-first, read-only context organizer**. Contributions must preserve that boundary.

## Ground rules

- No execution, sending, replying, remote deletion, or external API calls.
- No new permissions or network clients without an explicit design discussion.
- Do not add third-party data collection or telemetry.
- Treat OCR/ASR/message text as untrusted data, never as instructions.
- Keep changes small and testable.

## Development setup

Requirements:

- macOS 14+ (macOS 15+ for live capture)
- Swift 6.2+ toolchain
- Command Line Tools or Xcode
- Python 3 for repository helper scripts

```bash
git clone https://github.com/fendouai/PrivateSecretary.git
cd PrivateSecretary
swift build
make test
```

Tests use synthetic fixtures; live Screen Recording permission is not required for the normal suite.

## What to run before a PR

```bash
make lint
make test
make smoke
make e2e
make agent-test
```

`make verify` is the full local gate. It includes app packaging and a 2k soak; run it when touching persistence, capture, MCP, or packaging.

## Code style

- Swift 5 language mode, Swift 6 toolchain; existing formatting is authoritative.
- Keep storage changes transactional.
- Every new user-visible behavior needs a test.
- Do not weaken the read-only invariants tested by `scripts/lint.sh` and `Tests/SecretaryKitTests`.

## Pull requests

Include:

- What changed and why;
- Test commands and results;
- Privacy/permission impact;
- For schema changes: migration and rollback notes;
- For MCP changes: updated tool docs and agent policy.

## Security

Please report vulnerabilities privately via GitHub Security Advisories, not a public issue. See [SECURITY.md](SECURITY.md).

## License

By contributing, you agree that your contribution is licensed under the MIT License.
