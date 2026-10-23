# Agent harness

The rules the native agent's loop (`AgentLoopProvider`) and the AI layer under it follow with each
provider: what a reply's reasoning needs to be sent back, how a round is capped, cached and retried,
how much a run may spend and how it ends. [Agents](agents.md) describes the agent itself (folder,
tools, consent, ACP); this page holds the per-provider evidence those rules rest on, so a change to one
starts from what the provider documents rather than from what seemed to work.

## Invariants

- **A reply's reasoning goes back only to the model that wrote it, on the route that served it.**
  `AIReasoningReplay` is stamped with the endpoint's host and the model id when it is decoded, and
  `AIReasoningReplayPolicy` compares both before sending a byte of it. Another model's reasoning, and
  a call signature from another model, are dropped from the request, never translated.
- **The reasoning goes back in the form it came in.** A `reasoning_content` field returns as that
  field, `reasoning` as `reasoning`, `reasoning_details` as the same entries in the same order, a
  `<think>` block as a `<think>` block in front of the answer, and an Anthropic `thinking` or
  `redacted_thinking` block as that block with its signature. Opaque entries (signatures, encrypted
  details, redacted blocks) are never read, edited or merged beyond pi's delta merge.
- **Opaque entries live only as long as the turn.** They ride the assistant messages of the turn's
  tool rounds inside one run and are never written to disk. A chat keeps a reply's reasoning text,
  route, model and form, so a later turn can send it to providers that read earlier turns' reasoning.
- **Upstream's loop and the fork's carry the same thing.** Both keep the reply's reasoning on the
  assistant message with its calls and pass the event on to the chat, so a plain chat with web search
  or MCP tools gets the same replay as an agent.

## Interleaved thinking

Reasoning models think between tool calls. Most of them must be sent their own earlier reasoning when
the tool results come back, or they lose the plan they were following, repeat calls, or refuse the
request outright. The providers disagree on the field, on which messages must carry it, and on whether
earlier user turns count, so the rules are per provider and pinned by
`Tests/ai-fixtures/reasoning-replay-bodies.json`: one conversation (an earlier turn of the same model,
one of another model, then a tool round) sent to every route below.

### The carrier

`AIReasoningDecoder`, fed by `AIStreamDecoder`, gathers one reply's reasoning:

| Stream shape | What is kept | `Form` |
| --- | --- | --- |
| `delta.reasoning_content` (DeepSeek, Qwen, Kimi, MiniMax M3, GLM, vLLM copies) | the text | `reasoningContent` |
| `delta.reasoning` (OpenRouter, newer vLLM) | the text | `reasoning` |
| `delta.reasoning_details` (OpenRouter, MiniMax with `reasoning_split`) | entries merged as pi merges them: neighbouring `reasoning.text` or `reasoning.summary` deltas grow one entry, a `reasoning.encrypted` entry stays whole; unknown types are dropped | `details` |
| `<think>…</think>` leading `delta.content` (MiniMax M2, local Qwen3 without a reasoning parser) | what `AIThinkTagDecoder` took out of the answer | `thinkTags` |
| Anthropic `content_block_start` `thinking` / `redacted_thinking`, `thinking_delta`, `signature_delta` | each block as it streamed, signature appended | `blocks` |
| `tool_calls[].extra_content.google.thought_signature` (Gemini) | the signature stays on `AIToolCall`; the reply is stamped | none |

It emits one `.reasoningReplay` per reply, before the reply's calls (or before `.finished` when there
are none). The loops put it on the assistant message that carries the calls (`AIMessage.reasoning`)
and pass it on; `AIChatState` keeps `AIReasoningReplay.stored` — the text, route, model and form,
never opaque entries, and nothing for Anthropic blocks, whose signature cannot outlive the turn — as
`ChatMessage.replay`, saved in `message_reasoning_replay` beside the message. A later turn's history
carries it back on that reply's `AIMessage` (`isStored`), and the policy decides whether the route
reads it.

### Per provider

`AIReasoningReplayPolicy.route(of:)` picks the provider by kind and host. "This turn" is the tool
rounds of the request being sent; "earlier turns" are history replies loaded from the chat.

| Provider (host) | Field sent back | This turn | Earlier turns | Body switch |
| --- | --- | --- | --- | --- |
| DeepSeek (`*.deepseek.com`) | `reasoning_content` | own text | own stored text; every other assistant message `""` | — |
| Qwen (`*.aliyuncs.com`, `*.qianwenai.com`) | as it came (`reasoning_content`) | yes | own stored text | Always: `preserve_thinking: true` |
| Moonshot Kimi (`moonshot.ai`, `moonshot.cn`, `kimi.com`, `kimi.ai`) | as it came (`reasoning_content`) | yes | own stored text | — |
| MiniMax (any host naming `minimax`) | as it came: `reasoning_content`, `reasoning_details` or `<think>` in `content` | yes | own stored text | — |
| Z.ai / Zhipu (`z.ai`, `bigmodel.cn`) | as it came (`reasoning_content`) | yes | own stored text | Always: `thinking: {type: enabled, clear_thinking: false}` |
| OpenRouter | `reasoning_details` verbatim, else `reasoning` | yes | Always only | — |
| Anthropic (`api.anthropic.com`) and Anthropic-shaped gateways | `thinking` / `redacted_thinking` blocks first in the message | yes | never | — |
| Gemini (`generativelanguage.googleapis.com`) | only the call's `extra_content.google.thought_signature` (upstream's) | signatures | — | — |
| OpenAI (`api.openai.com`) | nothing | — | — | — |
| Any other OpenAI-compatible host | as it came | yes | Always only | — |

Nothing goes back while the connection's thinking is switched off (`disablesThinking`), and nothing
from a reply another model wrote. The rules, provider by provider:

- **DeepSeek.** [Thinking mode](https://api-docs.deepseek.com/guides/thinking_mode): "the
  `reasoning_content` must be fully passed back to the API in all subsequent requests" when the
  request has `tools`, "even for turns where the model did not perform a tool call", and "If your code
  does not correctly pass back `reasoning_content`, the API will return a 400 error." Without tools it
  is ignored. Thinking is on by default (`thinking: {type: enabled|disabled}`, `reasoning_effort`).
  So with tools and thinking on, every assistant message carries the field: this turn's own text, an
  earlier turn's stored text when the same model wrote it, otherwise `""` — pi's
  `requiresReasoningContentOnAssistantMessages`, which its changelog records as the fix for DeepSeek V4
  replay 400s. The empty field is not reasoning, so it is sent even when the connection says Never.
  DeepSeek's Anthropic endpoint (`/anthropic`, which DeepSeek Harness uses) takes thinking blocks with
  signatures; Redcast replays them within the turn like Claude's.
- **Qwen (Alibaba Cloud Model Studio, Qwen Cloud).** [Deep thinking](https://help.aliyun.com/en/model-studio/deep-thinking):
  `enable_thinking` switches hybrid models; `preserve_thinking` "controls whether the model reads from
  historical assistant messages `reasoning_content`", and turning it on "doesn't cause an error if the
  history has no `reasoning_content`". The function-calling guide appends the full assistant message,
  `reasoning_content` and `tool_calls` included, inside the tool loop. Earlier turns' text is sent; the
  model reads it only where `preserve_thinking` is on, which Always asks for.
- **Moonshot Kimi.** [Thinking models](https://platform.kimi.ai/docs/guide/use-kimi-k2-thinking-model):
  in a tool loop "keep all of the reasoning content from the context (the `reasoning_content` field) and
  send it back"; across turns `thinking.keep` decides (`kimi-k2.6` defaults to not kept), while
  `kimi-k2.7-code` and the K3 models always keep it and must be sent historical `reasoning_content`
  as-is. `kimi-k3.1-pro` "should not" be sent a `thinking` parameter at all, so Redcast never sends
  `keep` and relies on the models that read history doing so by default.
- **MiniMax.** [M2/M3 tool use](https://platform.minimax.io/docs/guides/text-m2-function-call):
  "return the model's full response each time — especially the thinking fields", "always append the
  full returned message to the history". The [OpenAI-compatible reference](https://platform.minimax.cn/docs/api-reference/text-openai-api)
  says `reasoning_split: true` moves thinking into `reasoning_content` (M3; older M2 builds put it in
  `reasoning_details`), and that without it the M2 models' `content` carries `<think>` which "must be
  kept in full". Redcast sends no `reasoning_split` and returns whichever form came.
- **Z.ai / Zhipu GLM.** [Thinking mode](https://docs.z.ai/guides/capabilities/thinking-mode):
  interleaved thinking is on by default and "thinking blocks should be explicitly preserved and
  returned together with the tool results"; Preserved Thinking keeps earlier turns' `reasoning_content`,
  on by default on the Coding Plan endpoint and off on the standard API until `clear_thinking: false`,
  and then "you must return the complete, unmodified reasoning_content". GLM-5.3 cannot switch thinking
  off. Earlier turns' stored text is sent (the server clears it unless preservation is on); Always
  turns preservation on. Redcast's history collapses a tool turn into its answer, so an earlier turn's
  text is the reasoning of the reply as saved, not every round's — Z.ai's "may degrade" case, which is
  why Automatic leaves the switch alone.
- **OpenRouter.** [Reasoning tokens](https://openrouter.ai/docs/guides/best-practices/reasoning-tokens):
  `reasoning_details` (`reasoning.summary`, `reasoning.encrypted`, `reasoning.text` with `signature`)
  passed back so that "the entire sequence of consecutive reasoning blocks must match the outputs
  generated by the model during the original request"; streamed as deltas to be concatenated in order.
  Gemini's thought signatures and Claude's thinking signatures travel inside those entries. pi merges
  the deltas the same way (`openai-completions.ts`). Only the turn's own entries go back; Always adds
  earlier turns' text as a `reasoning.text` entry.
- **Anthropic.** [Thinking with tool use](https://platform.claude.com/docs/en/build-with-claude/thinking):
  "Required: within a tool-use turn, pass thinking blocks back", complete and unmodified, alongside the
  `tool_use` they accompanied, redacted ones included; "Modified thinking blocks are rejected with a
  400 error". Claude Opus 5.5, Sonnet 5.5 and the other 5.x models think by default with no `thinking`
  field, and `display` defaults to `omitted`: the block arrives with an empty `thinking` and a
  signature, and still has to go back. Since August 2026 a block is also bound to everything sent
  before it ([preserved thinking](https://platform.claude.com/docs/en/build-with-claude/preserved-thinking)):
  shortening an earlier `tool_result` invalidates every later block, and a request carrying one fails
  with 400 on accounts the check applies to; dropping blocks from the end is valid. So when the agent
  loop elides a result or sheds history mid-turn, `AgentTurnBudget.unbind` drops every Claude block
  after the edit, on `api.anthropic.com` and on OpenRouter's `anthropic/` models, and never puts one
  back. Earlier turns' blocks are not stored (Redcast keeps no signatures), which the API allows:
  "outside tool use, omit prior turns' thinking". pi and DeepSeek Harness replay blocks the same way.
- **Gemini.** Gemini 3 attaches `thought_signature` to function calls, and the API "enforces strict
  validation on the current turn": a call sent back without its signature is a 400. Through the
  OpenAI-compatible endpoint it arrives as `tool_calls[].extra_content.google.thought_signature`
  ([OpenAI compatibility](https://ai.google.dev/gemini-api/docs/openai)), which upstream already
  decodes and returns. The fork stamps the reply so the signature is dropped if the message were ever
  sent to another model; no reasoning text is sent, since the compatible endpoint defines no field
  for it.
- **OpenAI.** Chat Completions returns no reasoning, so nothing is decoded and nothing is sent; an
  unknown message field could only cost a 400.
- **Any other OpenAI-compatible host.** The reasoning goes back within the turn in the form it came
  (`reasoning_content` as pi does for every compatible endpoint, `<think>` for templates that keep it
  in the content), which is what vLLM, SGLang and llama.cpp chat templates expect inside a tool loop.
  Earlier turns only with Always.

### The connection's override

Settings → AI → Providers → a connection's editor → Send reasoning back: **Automatic** (stored as
nothing) follows the table; **Always** also sends earlier turns' text to every route but OpenAI and
Gemini, and turns preservation on where a switch exists (Z.ai, Qwen); **Never** sends no reasoning and
no thinking blocks (DeepSeek's empty field stays, since without it the request is refused).
`AIConnection.reasoningReplay` is an optional key a previous build ignores; its save drops it, which
reads as Automatic.

### What breaks when it is wrong

| Wrong | Result |
| --- | --- |
| DeepSeek message without `reasoning_content` while tools are offered | HTTP 400 on the next round |
| Claude thinking block missing, edited or after an edited result | HTTP 400, or the reasoning silently dropped |
| Gemini 3 call without its signature in the current turn | HTTP 400 |
| Reasoning dropped on Kimi, MiniMax, GLM, Qwen inside a tool loop | the model loses its plan: repeated calls, wrong tool use |
| Another model's reasoning or signature sent | the target rejects the signature, or reads a stranger's thoughts as its own |

## Layout

| File | Holds |
| --- | --- |
| `AI/Model/AIRequest.swift` (fork block) | `AIReasoningReplay`: route, model, form, text, opaque items, stored or live |
| `ReasoningReplay/Model/AIReasoningDecoder.swift` | One reply's reasoning from any stream shape; pi's details merge |
| `ReasoningReplay/Model/AIReasoningReplayPolicy.swift` | The provider table above, per message and per body |
| `AI/Model/AIConnection.swift` (fork lines) | The connection's override and the configuration's route |
| `AI/Service/ChatHistoryStore.swift` (fork lines) | `message_reasoning_replay`, one row per reply that kept reasoning |
| `Agents/Model/AgentTurnBudget.swift` | `unbind`: Claude's blocks after an edit |
