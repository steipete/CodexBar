# Security Policy

## Reporting a vulnerability

Please report suspected vulnerabilities through GitHub's private [Report a Vulnerability](https://github.com/steipete/CodexBar/security/advisories/new) flow. Do not open a public issue until a maintainer has confirmed that disclosure is safe.

Include a minimal reproduction, affected CodexBar version, macOS/Linux version, impact, and the exact capability required to reproduce. A maintainer will coordinate disclosure before publishing a fix.

Never attach API keys, cookies, Keychain exports, `auth.json` files, browser databases, complete account identities, or unredacted request/response logs. Redact secrets before sharing diagnostics.

## Threat model

CodexBar can interact with provider OAuth/API credentials, browser cookies and local storage, Keychain items, local configuration/session files, provider CLIs, WebKit, widgets, and signed update artifacts. These are distinct trust boundaries. A report is especially useful when it demonstrates that CodexBar can:

- Read, disclose, or persist credentials or private data outside its documented scope.
- Access a Keychain item, browser profile, local file, or subprocess without the expected user consent or boundary.
- Cross provider identity, plan, or usage data between accounts.
- Bypass a permission, redaction, update-signature, or localhost/export access control.
- Execute untrusted content or make network requests outside the expected provider integration.

## Out of scope

The following are normally out of scope unless CodexBar itself expands the impact:

- A third-party provider outage, account policy, billing decision, or undocumented API behavior.
- Credentials deliberately supplied by the user to a provider integration.
- Attacks that require local administrator access or an already-compromised macOS/Linux account.
- Bugs in an external CLI, browser, or provider service that CodexBar does not invoke or bundle.

Reports are evaluated on reproducible impact, not on whether AI tools assisted their preparation. The reporter is responsible for understanding the report and providing original evidence.
