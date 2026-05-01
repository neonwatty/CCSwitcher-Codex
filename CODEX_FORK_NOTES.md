# CCSwitcher Codex Private Fork Notes

This branch is a private/local Codex experiment. It intentionally uses local bundle
identifiers and Keychain service names so it does not replace the installed
`/Applications/CCSwitcher.app`.

## What Works

- Detects the Codex CLI from common install paths, including NVM.
- Reads Codex ChatGPT auth from `~/.codex/auth.json`.
- Derives Codex account identity from `tokens.account_id` and the `id_token`.
- Stores per-account Codex auth snapshots in the macOS Keychain.
- Fetches Codex usage from `https://chatgpt.com/backend-api/wham/usage`.
- Maps Codex `primary_window` to the existing session meter and
  `secondary_window` to the weekly meter.
- Adds provider-specific add/login buttons for Claude Code and Codex.
- Treats Claude Code and Codex as independently active providers, so both can
  be monitored at the same time.
- Parses Codex cost/activity from local `~/.codex/logs_2.sqlite` and
  `~/.codex/history.jsonl`, then combines those summaries with Claude Code.

## Local Build

```sh
xcodegen generate
xcodebuild -project CCSwitcher.xcodeproj -scheme CCSwitcher -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The local copy created during development is:

```text
/Users/neonwatty/Desktop/CCSwitcher-Codex.app
```

## Known Limits

- The Codex usage endpoint is private and can change.
- Multi-Codex-account switching is implemented but not fully verified on this
  machine because only one Codex account was available during this pass.
- Codex line-count/tool-use parsing is not implemented yet. Codex turns,
  active time, model usage, token usage, and API-equivalent cost are included.
- The upstream repo appears to have no explicit license metadata, so keep this
  private/local unless that is resolved.
