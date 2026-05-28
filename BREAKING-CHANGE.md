# Claude Code v2.1.153+ Breaks Third-Party API Proxies

**Date:** 2026-05-28  
**Reporter:** jlaiii  
**Affected:** All third-party Anthropic-compatible API proxies (DeepSeek, OpenRouter, etc.)

---

## Summary

Claude Code v2.1.153 introduced a breaking change that makes the CLI incompatible with third-party Anthropic-compatible API endpoints. The last fully working version is **v2.1.143**.

---

## What Changed

Claude Code v2.1.153+ activates [extended thinking](https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking) **by default** for all supported models (opus, sonnet). This is a departure from v2.1.143 which either did not use extended thinking or allowed it to be disabled.

The documented environment variable `CLAUDE_CODE_DISABLE_THINKING=1` — which is supposed to "force-disable extended thinking regardless of model support or other settings" — is **ignored** by v2.1.153. All related thinking-disabling env vars (`MAX_THINKING_TOKENS=0`, `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1`, `DISABLE_INTERLEAVED_THINKING=1`) are similarly non-functional.

---

## How It Breaks

### The Thinking Block Protocol

When extended thinking is active, the Anthropic API protocol works like this:

1. Claude Code sends a request with thinking enabled
2. The API responds with `[thinking block]` + `[text/tool_use response]`
3. The thinking block contains thinking content + a cryptographic **signature**
4. On the next API call, the thinking block **must** be included in the conversation history
5. The API validates the signature against the thinking content

### Why Third-Party Proxies Can't Support This

Third-party proxies (like DeepSeek's `/anthropic` endpoint) return thinking blocks with:

- **Garbled binary thinking content** — Not human-readable thinking text, but encoded/encrypted data
- **Invalid signatures** — DeepSeek uses request IDs as signatures, not valid cryptographic signatures tied to the thinking content
- **Thinking-on-empty** — Even when the client sends `thinking: {type: "disabled"}`, DeepSeek still returns thinking blocks, consuming token budget with empty thinking content

The result is a catch-22:
- **Keep the thinking blocks** → DeepSeek rejects the garbled content + invalid signature → 400 error
- **Remove the thinking blocks** → DeepSeek complains they're missing (protocol requires them) → 400 error
- **Empty the thinking text** → DeepSeek rejects because empty text doesn't match the signature → 400 error

### Error Message

```
API Error: 400
The `content[].thinking` in the thinking mode must be passed back to the API.
```

This error appears on the **second** API call in a multi-turn conversation (e.g., after Claude Code runs a tool and sends the result back). Simple single-turn prompts without tool use may work, but any prompt requiring tools (file reads, code searches, etc.) will fail.

---

## Attempted Fixes (All Failed)

| Attempt | Result |
|---------|--------|
| `CLAUDE_CODE_DISABLE_THINKING=1` | Ignored by v2.1.153 |
| `MAX_THINKING_TOKENS=0` | Ignored |
| `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1` | Ignored |
| `DISABLE_INTERLEAVED_THINKING=1` | Ignored |
| `--effort low` flag | Thinking still used |
| `--bare` flag | Thinking still used |
| `alwaysThinkingEnabled: false` in settings.json | Ignored |
| Custom `--settings` file with all above | Ignored |
| JavaScript proxy stripping thinking from requests | DeepSeek returns thinking anyway |
| JavaScript proxy stripping thinking from responses | Breaks SSE content block indices |
| JavaScript proxy keeping thinking with empty content | Signature validation fails |
| Force `thinking: {type: "disabled"}` in requests | DeepSeek returns `reasoning_effort` conflict error |

---

## Conclusion

This appears to be a **genuine bug** in Claude Code v2.1.152+ rather than an intentional proxy-lock. Evidence:

1. The exact same 400 error occurs on the **official Anthropic API** during long conversations (Issue #62756)
2. It also manifests on **gateway proxies** (Issue #61348, DeepSeek, etc.)
3. The `CLAUDE_CODE_DISABLE_THINKING` env var is documented but non-functional — likely a regression, not intentional
4. The deprecated `thinking.type.enabled` format bug in Issue #61348 is explicitly a bug (Windows works, Mac doesn't)

However, the impact is more severe through third-party proxies because:
- Anthropic's official API has working thinking signatures (the bug is intermittent)
- Third-party proxies can't generate valid signatures at all (the bug is permanent)
- This makes the thinking protocol fundamentally incompatible with any non-Anthropic endpoint

Whether intentional or not, the practical effect is that Claude Code v2.1.153+ is effectively locked to Anthropic's API for reliable tool-based conversations.

---

## Workaround

**Downgrade to v2.1.143:**

```bash
claude install 2.1.143
```

**Prevent auto-updates:**

```bash
# Windows (PowerShell as admin)
[Environment]::SetEnvironmentVariable("DISABLE_AUTOUPDATER", "1", "User")

# Or set DISABLE_AUTOUPDATER=1 in ~/.claude/settings.json env block
```

---

## Affected Providers

| Provider | Status | Notes |
|----------|--------|-------|
| Anthropic Official API | ⚠️ Intermittent | Same 400 error reported in long conversations with tool use (Issue #62756) |
| DeepSeek `/anthropic` | ❌ Broken | Returns malformed thinking blocks with garbled content + invalid signatures |
| OpenRouter | ❌ Likely broken | Same protocol incompatibility — any proxy that doesn't properly implement Anthropic's thinking signature protocol |
| Any Anthropic-compatible proxy | ❌ Broken | Cannot replicate proprietary thinking signature validation |

**Key finding:** This is NOT purely a proxy-targeting change. The bug also affects official Anthropic API users on long conversations (reported in [Issue #62756](https://github.com/anthropics/claude-code/issues/62756)). The thinking feature appears to have inherent bugs in v2.1.152+ that manifest more severely through third-party proxies.

## Related Issues on GitHub

- **[#62756](https://github.com/anthropics/claude-code/issues/62756)** — Same error on official Anthropic API (Windows 10, v2.1.152, VS Code). "The error appears randomly, sometimes multiple times per session... makes long sessions frustrating and unreliable." Opened May 27, 2026.
- **[#61348](https://github.com/anthropics/claude-code/issues/61348)** — Claude for Mac sends deprecated `thinking.type.enabled` (should be `thinking.type.adaptive`) for Opus 4.7, causing 400 errors through gateway proxies. Opened May 22, 2026.
- **[#59536](https://github.com/anthropics/claude-code/issues/59536)** — Feature request for per-model beta-feature opt-out for proxy/gateway-routed deployments (closed as duplicate).

---

## What Needs to Happen

Since this also affects official API users, Anthropic is likely to fix it. The possible resolution paths:

1. **Most likely**: Anthropic fixes the thinking block handling bug — this benefits both official API and proxy users
2. **Possible**: Anthropic makes `CLAUDE_CODE_DISABLE_THINKING=1` functional again
3. **Unlikely**: Anthropic makes extended thinking opt-in instead of default-on
4. **Unlikely**: DeepSeek implements proper thinking signature protocol
5. **Unlikely**: Third-party proxies independently support Anthropic's thinking signature format

**Our position**: Pin to v2.1.143 until Anthropic ships a fix. When they do, test it against DeepSeek and update `approved-versions.json`.

---

## Related Files

- Approved versions: `approved-versions.json` (pins Claude Code to v2.1.143)
- Launcher safety net: `DeepSeek-Launcher.bat` shows `!UNSAFE!` warning for unapproved versions
- Proxy reference: `claude-deepseek-proxy.js` (works for simple prompts only, included for reference)
