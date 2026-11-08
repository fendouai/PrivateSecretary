# Security Policy

## Supported versions

The current `main` branch and the latest tagged release receive security fixes.

## Reporting a vulnerability

Please use **GitHub Security Advisories** for private vulnerability reports:

https://github.com/fendouai/PrivateSecretary/security/advisories/new

Do not open a public issue containing private data, memory contents, credentials, TCC details, or reproduced vulnerabilities.

## Scope

In scope:

- The read-only boundary (execution, sending, external writes);
- MCP tool authorization and data exposure;
- Local privilege/permission handling;
- SQLite injection, malformed imports, prompt injection;
- TCC / app bundle signing issues;
- Path traversal or unsafe file handling;
- Dashboard XSS/CSP.

Out of scope:

- Third-party channel APIs and credentials;
- The security of the user's own local machine;
- Agent host behavior (Codex/Claude/Cursor);
- Cloud model providers.

## Design principles

- No execution or external side effects;
- All data stays local by default;
- Observed content is untrusted data;
- File permissions 0700/0600;
- No secrets in the repository.
