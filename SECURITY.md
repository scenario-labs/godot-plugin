# Security Policy

## Reporting a vulnerability

Do not report security vulnerabilities through public GitHub issues or pull
requests. Public reports can expose other users before a fix is available, and
copies may remain accessible after deletion.

Report privately through any of these channels:

- [Open a private vulnerability report](https://github.com/scenario-labs/godot-plugin/security/advisories/new)
  from this repository's Security tab.
- Email [support@scenario.com](mailto:support@scenario.com) with "security" in the subject.
- Use in-app support at [app.scenario.com](https://app.scenario.com).

Include the affected surface (the Godot plugin or the Scenario platform), the
Godot and plugin versions, reproduction steps and the impact you observe. The
plugin version is shown in Project > Project Settings > Plugins and in
`addons/scenario/plugin.cfg`. Use synthetic credentials and minimal sample
projects where possible. Scenario support routes reports to the appropriate team
and follows up through the same private channel.

## Scope

This repository ships Scenario for Godot, an editor plugin. It stores Scenario
API credentials, calls the Scenario MCP server at `mcp.scenario.com`, downloads
generated files and imports them into the open project. Relevant reports include:

- Unexpected exposure of keys or secrets through the project folder, logs,
  errors, provenance files or network requests, including the macOS Keychain
  entry, the user-only file in the editor settings folder, and
  `SCENARIO_API_KEY` / `SCENARIO_API_SECRET`.
- Paid requests sent twice, sent without a matching price check, or sent while
  `SCENARIO_NO_SPEND=1` is set.
- Unsafe downloads or imports of images, glTF/GLB, audio or other generated
  content, including files written outside `res://scenario/`.
- The repository's CI and release supply chain: how the release zip is
  built and published, and what it contains.

Platform vulnerabilities involving `app.scenario.com`, `api.cloud.scenario.com`
or `mcp.scenario.com` use the same private channels above, not this repository's
public issue tracker.

## Supported versions

Security fixes target the [latest release](https://github.com/scenario-labs/godot-plugin/releases).
Report suspected vulnerabilities promptly even if you cannot update or
reproduce them on the latest version. Older releases have no support branch.

## Secrets in issues and pull requests

API keys and secrets and signed asset URLs are credentials. Never commit them or
paste them into public issues or pull requests. Check screenshots, logs and
sample projects before sharing them. If a secret is already exposed, report it
privately instead of pointing to it in a public issue, and revoke the key in
Scenario.
