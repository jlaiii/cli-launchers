# Claude Code v2.1.153+ Breaks Third-Party API Proxies

**Date:** 2026-05-29  
**Reporter:** jlaiii  
**Affected:** All third-party Anthropic-compatible API proxies (DeepSeek, OpenRouter, etc.)  
**Last tested:** v2.1.156 (BROKEN) | **Last known good:** v2.1.143

---

## Summary

Claude Code v2.1.153+ introduced **two separate breaking changes** that make the CLI incompatible with third-party Anthropic-compatible API endpoints. The last fully working version is **v2.1.143**.

| Version | Issue | Status |
|---------|-------|--------|
| v2.1.153 | Thinking blocks with garbled binary data → 400 on turn 2 | DeepSeek side FIXED ✓ |
| v2.1.154+ | System as `role:"system"` in messages array → 400 on turn 1 | STILL BROKEN ✗ |

---

## ISSUE A: Thinking Block Protocol (v2.1.153)

### What Changed

Claude Code v2.1.153+ activates [extended thinking](https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking) **by default** for all supported models (opus, sonnet). This is a departure from v2.1.143 which either did not use extended thinking or allowed it to be disabled.

The documented environment variable `CLAUDE_CODE_DISABLE_THINKING=1` — which is supposed to "force-disable extended thinking regardless of model support or other settings" — is **ignored** by v2.1.153. All related thinking-disabling env vars (`MAX_THINKING_TOKENS=0`, `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1`, `DISABLE_INTERLEAVED_THINKING=1`) are similarly non-functional.

### How It Breaks

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

### Update (2026-05-29): DeepSeek Fixed Their Side

Direct API testing shows that DeepSeek now returns **human-readable thinking text** (not garbled binary). Multi-turn conversations with thinking blocks work correctly via the direct API. The thinking block issue appears **RESOLVED** on DeepSeek's end.

**However**, this is now blocked by Issue B below (v2.1.154+ system message format change), which prevents any API call from reaching the thinking stage.

---

## ISSUE B: System Messages in Messages Array (v2.1.154+) ← NEW

### What Changed

v2.1.154 changelog: *"The lean system prompt is now the default for all models except Haiku, Sonnet, and Opus 4.7 and earlier"*

Claude Code v2.1.154+ sends the system prompt as `role: "system"` **inside the `messages` array** (newer Anthropic API format), instead of using the top-level `"system"` field.

### How It Breaks

DeepSeek's `/anthropic` endpoint only supports the **top-level** `"system"` field:

```json
// Top-level system field (Anthropic spec, WORKS with DeepSeek ✓)
{
  "model": "claude-sonnet-4-6",
  "max_tokens": 50,
  "system": "You are a helpful assistant.",
  "messages": [{"role": "user", "content": "say hello"}]
}
```

v2.1.154+ sends the system prompt inside the messages array:

```json
// System in messages array (new Anthropic format, FAILS with DeepSeek ✗)
{
  "model": "claude-sonnet-4-6",
  "max_tokens": 50,
  "messages": [
    {"role": "system", "content": "You are helpful."},
    {"role": "user", "content": "say hello"}
  ]
}
```

DeepSeek rejects this with:

```
API Error: 400
Failed to deserialize the JSON body into the target type:
messages[1].role: unknown variant `system`, expected `user` or `assistant`
```

### Impact

- **v2.1.153**: Thinking block protocol incompatible → 400 on turn 2 (multi-turn)
- **v2.1.154+**: System messages incompatible → **400 on turn 1 (INSTANT FAIL)**
- Simple prompts (`--print` mode) also fail instantly
- No workaround exists other than downgrading

### Root Cause

This is a Claude Code format change, not a DeepSeek bug. Anthropic updated their API to accept `role: "system"` in the messages array. DeepSeek has not implemented this yet.

---

## Attempted Fixes (All Failed)

| Attempt | Issue | Result |
|---------|-------|--------|
| `CLAUDE_CODE_DISABLE_THINKING=1` | A | Ignored by v2.1.153 |
| `MAX_THINKING_TOKENS=0` | A | Ignored |
| `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1` | A | Ignored |
| `DISABLE_INTERLEAVED_THINKING=1` | A | Ignored |
| `--effort low` flag | A | Thinking still used |
| `--bare` flag | A | Thinking still used |
| `alwaysThinkingEnabled: false` in settings.json | A | Ignored |
| Custom `--settings` file with all above | A | Ignored |
| JavaScript proxy stripping thinking from requests | A | DeepSeek returns thinking anyway |
| JavaScript proxy stripping thinking from responses | A | Breaks SSE content block indices |
| JavaScript proxy keeping thinking with empty content | A | Signature validation fails |
| Force `thinking: {type: "disabled"}` in requests | A | DeepSeek returns `reasoning_effort` conflict error |
| JavaScript proxy moving system to top-level | B | Not yet attempted; may work as a proxy fix |

---

## Conclusion

This appears to be a **genuine bug** in Claude Code v2.1.152+ rather than an intentional proxy-lock. Evidence:

1. The exact same 400 error occurs on the **official Anthropic API** during long conversations (Issue #62756)
2. It also manifests on **gateway proxies** (Issue #61348, DeepSeek, etc.)
3. The `CLAUDE_CODE_DISABLE_THINKING` env var is documented but non-functional — likely a regression, not intentional
4. The deprecated `thinking.type.enabled` format bug in Issue #61348 is explicitly a bug (Windows works, Mac doesn't)
5. The system message format change (v2.1.154+) is a normal API evolution, not a proxy-targeting change

However, the impact is more severe through third-party proxies because:
- Anthropic's official API has working thinking signatures (the bug is intermittent)
- Third-party proxies can't generate valid signatures at all (the bug is permanent)
- DeepSeek's endpoint doesn't support the new system message format
- This makes Claude Code v2.1.153+ effectively locked to Anthropic's API for reliable tool-based conversations

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
| DeepSeek `/anthropic` | ❌ Broken | v2.1.154+: system messages rejected. v2.1.153: thinking block issue (now resolved on DeepSeek side but blocked by system msg issue) |
| OpenRouter | ❌ Likely broken | Same protocol incompatibility — any proxy that doesn't properly implement Anthropic's thinking signature protocol or system message format |
| Any Anthropic-compatible proxy | ❌ Broken | Cannot replicate proprietary thinking signature validation + new system message format |

**Key finding:** This is NOT purely a proxy-targeting change. The bugs also affect official Anthropic API users on long conversations (reported in [Issue #62756](https://github.com/anthropics/claude-code/issues/62756)). The thinking feature appears to have inherent bugs in v2.1.152+ that manifest more severely through third-party proxies.

## Related Issues on GitHub

- **[#62756](https://github.com/anthropics/claude-code/issues/62756)** — Same error on official Anthropic API (Windows 10, v2.1.152, VS Code). "The error appears randomly, sometimes multiple times per session... makes long sessions frustrating and unreliable." Opened May 27, 2026.
- **[#61348](https://github.com/anthropics/claude-code/issues/61348)** — Claude for Mac sends deprecated `thinking.type.enabled` (should be `thinking.type.adaptive`) for Opus 4.7, causing 400 errors through gateway proxies. Opened May 22, 2026.
- **[#59536](https://github.com/anthropics/claude-code/issues/59536)** — Feature request for per-model beta-feature opt-out for proxy/gateway-routed deployments (closed as duplicate).

---

## What Needs to Happen

Since this also affects official API users, Anthropic is likely to fix the thinking block handling bug. The system message format is a different challenge:

1. **Most likely**: Anthropic fixes the thinking block handling bug — this benefits both official API and proxy users
2. **Possible**: Anthropic makes `CLAUDE_CODE_DISABLE_THINKING=1` functional again
3. **Possible**: DeepSeek adds support for `role: "system"` in the messages array (it's now part of the official Anthropic API spec)
4. **Possible**: A proxy fix that moves system messages from the messages array to the top-level `system` field before forwarding to DeepSeek
5. **Unlikely**: Anthropic makes extended thinking opt-in instead of default-on
6. **Unlikely**: DeepSeek implements proper thinking signature protocol
7. **Unlikely**: Anthropic reverts the system message format change or provides an opt-out flag

**Our position**: Pin to v2.1.143 until:
- DeepSeek supports `role: "system"` in messages array, **AND**
- The thinking block handling is stable

When both issues are resolved, test against DeepSeek and update `approved-versions.json`.

---

## Related Files

- Approved versions: `approved-versions.json` (pins Claude Code to v2.1.143)
- Launcher safety net: `DeepSeek-Launcher.bat` shows `!UNSAFE!` warning for unapproved versions
- Proxy reference: `claude-deepseek-proxy.js` (works for simple prompts only, included for reference)
- Verification report: `v2.1.156-verification-report.txt` (detailed test results)
