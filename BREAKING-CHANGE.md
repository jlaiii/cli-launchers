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

This appears to be an intentional change by Anthropic. Extended thinking requires cryptographic signature validation that only Anthropic's own API infrastructure can perform. By making thinking mandatory and the documented disable flags non-functional, Claude Code v2.1.153+ is effectively locked to Anthropic's official API.

Third-party proxies cannot replicate the thinking signature protocol because:
1. The thinking content is tied to Anthropic's internal model infrastructure
2. The signature scheme is proprietary and tied to Anthropic's API keys
3. Even if a proxy could generate valid thinking content, it would need Anthropic's signing keys

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

Tested and confirmed broken:
- ✅ DeepSeek (`api.deepseek.com/anthropic`)
- ❓ OpenRouter (likely same issue)
- ❓ Any other Anthropic-compatible proxy endpoint

Works with:
- ✅ Anthropic official API (requires Anthropic API key or subscription)

---

## What Needs to Happen

For this to work with third-party proxies, one of these must occur:

1. **Anthropic** makes `CLAUDE_CODE_DISABLE_THINKING=1` functional again in a future release
2. **Anthropic** makes extended thinking opt-in (not default-on)
3. **DeepSeek** fixes their `/anthropic` endpoint to properly support the thinking protocol (unlikely — it's tied to Anthropic's proprietary infrastructure)
4. **DeepSeek** properly handles `thinking: {type: "disabled"}` and stops returning thinking blocks

Until one of these happens, **Claude Code v2.1.143** is the last version that works with third-party API proxies.

---

## Related Files

- Approved versions: `approved-versions.json` (pins Claude Code to v2.1.143)
- Launcher safety net: `DeepSeek-Launcher.bat` shows `!UNSAFE!` warning for unapproved versions
- Proxy reference: `claude-deepseek-proxy.js` (works for simple prompts only, included for reference)
