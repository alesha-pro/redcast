# Codex (ChatGPT) provider

A **Codex (ChatGPT)** API connection signs in with the reader's ChatGPT account and answers on that
plan's Codex usage, on the fork's own transport: no API key, no `codex` binary, no ACP. It is added
from the **+** menu of Settings → AI → Providers next to the key-based presets, and its models and
reasoning efforts appear in every picker an API connection reaches: Quick AI, AI Chat, agents, Quick
Actions and extension AI. Its limits come with the replies the reader already asks for, and
Settings shows the last snapshot with its age. It is the fork's, kept to `Features/CodexProvider/`
plus the `Fork:` lines listed under [Upstream touches](#upstream-touches).

It uses OpenAI's **Sign in with ChatGPT for open-source apps** (SIWC), the route OpenAI documents
for this, rather than the Codex CLI's own login. [Is it allowed?](#is-it-allowed) explains why.

## Invariants

- **Nothing runs until asked.** `AppCore.codexPlan` is lazy, and creating it does no work. There
  are no timers or watchers, and no listener stays open. The Keychain items and the limits file are
  read when the Providers panel or the Usage section opens, or when a request needs a token. Nothing
  reads `~/.codex`, the Codex CLI's sessions or its `auth.json`.
- **The callback listener exists only during sign-in.** `CodexPlanCallbackListener` binds
  `127.0.0.1:4965` (clear of MCP's 4962 and its test stub's 4963) when Continue with ChatGPT is
  pressed, before the browser opens, and closes on
  the first valid callback, on Cancel, after five minutes, or when the sign-in is superseded. It
  answers one request; a request without the attempt's `state` can neither sign in nor deny.
- **Tokens live only in the login Keychain.** One item per connection in
  `KeychainSecretStore.codexPlanCredentials` (`<bundle id>.codex-plan-credentials`, keyed by the
  connection's UUID) holds a JSON `CodexPlanCredentials`. That record carries the host id, the
  issued client id, the account's subject, email and plan, the last ID token, and the token set.
  Tokens never enter `UserDefaults`, `settings.json`, a backup, a log, a URL or an error message.
  The connection itself is an ordinary `AIConnection` with `provider == .codexPlan` and no key.
- **Refresh is lazy and serialized.** A token is refreshed only when a request is about to use it
  and it is within 60 seconds of expiry, or when the API just refused it (one retry per request).
  One refresh runs per connection at a time, because the refresh token rotates and a second
  refresh would spend it. Only a rejected grant (`invalid_grant`, `refresh_token_reused`, …, or a
  400/401 without a code) clears the tokens and asks for a sign-in. A network failure or 5xx keeps
  them, and the request fails as transient.
- **Never polled.** Limits are read from the headers and stream events of the user's own Responses
  requests. No endpoint is ever called for them, because the sanctioned route documents none (see
  [Limits](#limits-with-no-polling)).
- **Stateless requests inside the route's rules.** Every request is `POST
  https://api.openai.com/v1/responses` with `store: false` and `stream: true`, the full history in
  `input`, and none of the fields the route refuses. Those include `temperature`,
  `max_output_tokens`, `previous_response_id`, `metadata` and `user`, so a chat's temperature and an
  agent round's output cap are not sent.
- **The Codex CLI route is untouched.** `.codex` selections, `ChatGPTSubscriptionManager`, the
  app-server and ACP Codex keep working as before; the two routes share nothing.

## Is it allowed?

Research for this feature, October 2026. The pages marked *read* were fetched and read. The others
were seen only through search results, since `openai.com/policies/*` and help.openai.com refuse
automated fetches.

- **OpenAI runs an official program for exactly this.** Since DevDay (29 September 2026), "Sign in
  with ChatGPT" lets an app use a user's ChatGPT plan for Responses API requests. It is self-serve
  for "open-source and locally hosted apps"; a paid or remotely hosted app goes through an
  [interest form](https://openai.com/form/sign-in-with-chatgpt-interest/). Read:
  [overview](https://developers.openai.com/siwc/token-sharing-open-source),
  [registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in),
  [accounts and sessions](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions),
  [token reference](https://developers.openai.com/siwc/token-sharing-open-source/token-reference),
  [models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference),
  [errors and recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery),
  [preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations),
  [UI/UX guidelines](https://developers.openai.com/siwc/ui-ux-guidelines).
  Redcast is an open-source app that runs locally, so it qualifies for self-serve.
- **That program rules out the CLI's route.** The inference page says not to point the app at
  ChatGPT's `backend-api` endpoints. The sign-in page asks for the app's own registration
  (`dynamic_agent_client`, which issues an `oaiapp_…` client) and a `127.0.0.1` redirect, never
  `localhost`. Reusing the Codex CLI's client id (`app_EMoamEEZ73f0CkXaXp7hrann`, port 1455) and
  calling `chatgpt.com/backend-api/codex/responses` is therefore the undocumented path. The
  [Codex app-server docs](https://learn.chatgpt.com/docs/app-server) (read) say "App-server
  authentication has never been permitted for commercial or hosted services". They also recommend
  that local and open-source apps migrate to Sign in with ChatGPT.
- **Terms.** The [Sign in with ChatGPT terms](https://openai.com/policies/sign-in-with-chatgpt-terms/)
  (search results only) require tokens obtained through OpenAI's supported sign-in flow. They forbid
  impersonating OpenAI or another application, and pooling, reselling or sharing plan usage. They
  require any persistent token storage to stay local and under the user's control. The general
  [terms of use](https://openai.com/policies/terms-of-use/) forbid getting around rate limits or
  protective measures and sharing account credentials. No clause found says a plan may be used only
  in OpenAI's own clients.
- **Licence and staff statements.** [openai/codex](https://github.com/openai/codex) is Apache-2.0,
  so reading its code to learn the wire format is fine. The licence grants no right to the service
  or the CLI's client registration, and no maintainer statement on third-party reuse of the client id
  was found ([#36886](https://github.com/openai/codex/issues/36886) asks and has no reply). Codex
  lead Thibault Sottiaux wrote in May 2026 that a ChatGPT account works "in a flourishing set of
  other tools" ([post](https://x.com/thsottiaux/status/2058071172361998482), search results only).
  Zed's [announcement](https://zed.dev/blog/chatgpt-subscription-in-zed) (read) says OpenAI
  "continues to support subscription-based access for third-party tools". This is the opposite of
  Anthropic, which blocked subscription OAuth in third-party tools from January 2026.
- **How others do it** (their source read on GitHub):

  | Tool | Client | Endpoint |
  | --- | --- | --- |
  | OpenCode | SIWC's `dynamic_agent_client` | `api.openai.com/v1`; its Codex-CLI-id methods are now labelled legacy |
  | Kilo Code, Cline, Zed's built-in ChatGPT provider | the Codex CLI's id, port 1455, their own `originator` | `chatgpt.com/backend-api/codex` |
  | numman-ali's `opencode-openai-codex-auth` | the Codex CLI's id | the backend; described by its author as personal use |
  | JetBrains, Xcode 26, Zed's Codex threads | ChatGPT sign-in of the Codex agent they run | the Codex agent itself |

  None of the CLI-id reusers shows public enforcement against it, but none is endorsed for that path
  either.

**Decision: there is no prohibition, so this was built on the sanctioned route.** The brief named
the Codex CLI's flow and backend. The research found an official route for this case, so Redcast
uses that instead. It registers its own client, signs in on `127.0.0.1`, calls
`api.openai.com/v1/responses` and `/v1/models`, and sends no Codex `originator`, version or
account-id headers. It never presents itself as Codex CLI.

**Residual risk:**

- SIWC is labelled preview, so fields, limits and terms can change.
- Usage headers on this route are not documented (see [Limits](#limits-with-no-polling)).
- The ID token is checked by claim and not by signature (see [Sign-in flow](#sign-in-flow)).
- OpenAI can disable an app's registration or a user's plan sharing; the error then says so.
- A paid or hosted distribution of Redcast would need OpenAI's approval through the interest form.

## Sign-in flow

`CodexPlanAccounts` (`@MainActor`, owned by `AppCore`) runs every step. `CodexPlanOAuth` builds and
checks each piece, Foundation-only and covered by `codex-plan-test`.

1. **Host id.** On a connection's first sign-in it gets `ext_agent_host_id = urn:uuid:<v4>`, which
   is saved in its Keychain record before the browser opens and kept across sign-outs.
2. **PKCE.** Each attempt makes a fresh `state`, `nonce` and verifier: 64 random bytes as unpadded
   base64url, with an S256 challenge.
3. **Authorize.** The listener starts, then the default browser opens
   `https://auth.openai.com/api/accounts/authorize`. The query carries `response_type=code`,
   `redirect_uri=http://127.0.0.1:4965/auth/callback`,
   `scope=openid profile email offline_access resource.invoke chatgpt.tokens.use.direct` and
   `resource=https://api.openai.com/v1`, plus the state, nonce, challenge and host id. A first sign-in
   adds `client_id=dynamic_agent_client` and `agent_name_hint` (the app's name). A later one sends
   the saved client id with `id_token_hint` and `login_hint`.
4. **Callback.** `GET /auth/callback?code&state&client_id&scope`. The state must match first, so a
   denial (`error=access_denied`) counts only with the attempt's state. A first sign-in must be
   issued an `oaiapp_…` client. A reauthorization may omit it, but must not return a different one.
5. **Exchange.** The code is posted as a form to `https://auth.openai.com/api/accounts/oauth/token`
   (`grant_type=authorization_code`, `client_id`, `code`, `code_verifier`, `redirect_uri`,
   `resource`). The response gives `access_token` (one hour), a rotating 30-day `refresh_token`,
   `id_token`, `expires_in`, `scope` and `earliest_refresh_at`.
6. **ID token.** Its `iss`, `aud`, `exp` (with two minutes' leeway), `nonce` and `sub` are checked.
   OpenID Connect Core §3.1.3.7 allows TLS server validation in place of the signature check when the
   token comes directly from the token endpoint over TLS, and it does here. Redcast does not fetch
   OpenAI's JWKS. A reauthorization that signs in as another `sub` is refused.
7. **Grant.** If the granted scopes lack `chatgpt.tokens.use.direct`, the connection stays signed in
   but says plan usage is not allowed, and requests fail with that message rather than going
   anywhere else.
8. **Models.** One `GET https://api.openai.com/v1/models` with the token. The `models` array is
   Codex's `ModelInfo`: `visibility: "list"` entries, ordered by `priority`, each with
   `supported_reasoning_levels` and `default_reasoning_level`. The public `data` shape is accepted
   too. The ids become the connection's `models`, and the levels its `reasoningOptions`, which
   `AIConnection.reasoningOptions(for:)` returns for this kind as-is. **Refresh Models** repeats the
   request.

**Refresh.** `grant_type=refresh_token` with the saved client id, the refresh token and `resource`,
and no `scope`. The token set is replaced together. A refresh that returns an ID token for the same
`sub` updates the email and plan.

**Sign Out** clears the access, refresh and ID tokens at once, then revokes the refresh token in the
background. The revocation endpoint comes from `/.well-known/openid-configuration` and must be on
`auth.openai.com`; it is retried once. The client id, host id, subject and email stay, so the next
sign-in reauthorizes the same registration. If revocation is not confirmed, a HUD says so and points
to ChatGPT settings, as SIWC asks. **Removing** the connection does the same and also deletes its
Keychain item and limits snapshot.

## Requests

`CodexPlanProvider` is an `AIProvider` like `HTTPAIProvider`. It uses a detached task on a private
`.ephemeral` session with `urlCache = nil`, reads the stream per line, and has the same transient
and recoverable errors. `CodexPlanRequestBody` builds the request:

- `instructions` carries the preamble or the agent's prompt. A `system` message becomes a
  `developer` message, because the route refuses system items.
- User text goes as `input_text` and images as `input_image` data URLs. Assistant text goes as
  `output_text`, calls as `function_call` (`call_id`, `name`, `arguments`), and results as
  `function_call_output`.
- Tools are `{"type": "function", "name", "description", "parameters", "strict": false}`, with
  `tool_choice: auto` (`none` on a hand-over round) and `parallel_tool_calls: true`.
- `reasoning: {summary: "auto", effort}` and `include: ["reasoning.encrypted_content"]` are sent
  only for a model whose catalog gives levels. `Default` sends no effort.
- `prompt_cache_key` is the conversation's id, so a chat's prefix stays cached across rounds.

`CodexPlanStreamDecoder` follows codex-api's `sse/responses.rs`:

| Event | Becomes |
| --- | --- |
| `response.output_text.delta` | `.text` |
| `response.reasoning_summary_text.delta`, `response.reasoning_text.delta` | `.thinking` and `.reasoning`; a new summary part starts after a blank line |
| `response.output_item.added` (`function_call`), `response.function_call_arguments.delta`, `response.output_item.done` | one `AIToolCall` per call id, emitted at the end in the model's order |
| `response.output_item.done` (`reasoning`) | kept for the replay, its `id` and `status` dropped (`store: false` keeps nothing to refer to) |
| `response.completed` | `.usage` (cached input counted outside `inputTokens`), then the replay, the calls and `.finished` |
| `response.incomplete` | the same, with `.outputLimit` when the reason is `max_output_tokens` |
| `response.failed`, `error` | the failure below |
| `codex.rate_limits` | a limits snapshot |

**Reasoning replay.** A reply's reasoning items go back with its tool calls in the same turn, on
the assistant message, before its `function_call` items. They go only to the model that wrote them,
on this route (`AIReasoningReplay.route == "codex-plan"`), and never when the connection says Never.
`form` is nil, so `stored` is nil and nothing reaches a chat's history. An earlier turn's reasoning
is never resent, as with OpenAI's own API in [agent harness](agent-harness.md#per-provider).

**Errors** (`CodexPlanFailure`):

| From | Says |
| --- | --- |
| `subscription_sharing_usage_limit_exceeded` (429), Codex's `usage_limit_reached` | the plan's limit is reached, and it resets *in 2 hours*. The time comes from the body's `resets_at` or the reply's spent window; otherwise the message points to ChatGPT settings → Usage. Never retried. |
| 401 after one refresh, `subscription_sharing_invalid_user` | the sign-in expired; sign in again in Settings → AI → Providers |
| `subscription_sharing_user_not_eligible` | this account cannot use its plan in other apps |
| `subscription_sharing_unsupported_capability` | names the refused `param` |
| 503, `subscription_sharing_usage_unavailable`, `…_user_unavailable` | unavailable right now, transient so a run may retry it |
| anything else | `AIProviderFailure`'s own description, secrets redacted |

## Limits with no polling

The owner's rule: no timers, no file watching, nothing reading `~/.codex`.

- **Source.** Every Responses reply's headers are parsed for Codex's `x-codex-primary-used-percent`,
  `-window-minutes` and `-reset-at`, and the `secondary` set. codex-api's
  `parse_rate_limit_for_limit` reads these on every Responses stream it opens, whatever the provider.
  A `codex.rate_limits` stream event, the WebSocket transport's carrier, is read too. A reply that
  carries neither leaves the last snapshot alone.
- **Snapshot.** `CodexPlanLimits` holds the primary and secondary windows (used percent, window
  minutes, reset time) and when it was captured. It is kept in memory and in
  `Application Support/<bundle id>/CodexPlan/limits.json`, written off-main after a reply and read
  the first time a pane shows it. It holds percentages and times only, no secret.
- **Shown** in the connection's Providers page (a bar and "% left" per window, "Resets in …",
  "As of 5 minutes ago") and as a **Codex limits** row in Settings → AI → Usage. Each has a **Manage
  Usage** link to `chatgpt.com/settings/usage`, which SIWC's UI guidelines ask for.
- **No Refresh request.** The brief allowed one click-only request to a usage endpoint if one
  existed. On this route none does: SIWC documents no usage or status endpoint, and the Codex CLI's
  `/status` reads `chatgpt.com/backend-api/wham/usage`, a `backend-api` endpoint this route must not
  call. So the only action is Manage Usage. Whether `api.openai.com` sends the `x-codex-*` headers to
  SIWC clients is not documented. Until a reply carries them, the row says "No limits yet. They
  arrive with your next reply."

## Upstream touches

Each line is marked `Fork:`:

- `AIConnection`: the `codexPlan` case, its title and base URL, and `reasoningOptions(for:)`.
- `AIBrand.resolve`: the case is OpenAI's.
- `AIProviderFactory.make`: a `codexPlan:` parameter and the branch that skips the key, plus its four
  callers in `AppCore`, `AIChatCoordinator` (two) and `ExtensionAICoordinator`.
- `AppCore.codexPlan`.
- `settingsEnvironment`: the environment object.
- `KeychainSecretStore.codexPlanCredentials`.
- `AIProvidersPanel`: the **+** item, the detail section, no Edit… button, the list caption, the load
  on appear, and the forget on removal.
- `AIConnectionEditorPanel`: the provider picker leaves the kind out.

Fork files: `VoiceRoutePolicy` (no audio route), `UsageSection` (the row) and
`SettingsSearchCatalog` (keywords and the Codex limits entry).

**Rollback.** A build from before this feature cannot decode a `codexPlan` connection. Its decoder
then drops the whole saved connection list, and every API connection disappears from that build.
Remove the Codex (ChatGPT) connections before `install.sh --rollback`, or expect them back only on
upgrading again, as long as the older build saved no connection in the meantime.

## Manual sweep

Signing in is for the owner. The rest needs a signed-in account, and none of it is automated.

1. Settings → AI → Providers → **+** → **Codex (ChatGPT)**. The row says Sign in required, and the
   page says Not signed in with **Continue with ChatGPT**. `lsof -iTCP:4965` shows nothing.
2. Press Continue with ChatGPT. The browser opens auth.openai.com, the page says "Waiting for the
   browser…", and `lsof -iTCP:4965 -sTCP:LISTEN` shows Redcast. Cancel: the listener is gone and the
   page is back to Not signed in. Sign in again and approve: the tab says to return to Redcast, a
   HUD says "You're using your ChatGPT plan", the account row shows the email (hidden until
   clicked) and the plan, the model count is filled in, and the listener is gone.
3. Keychain Access: one `…codex-plan-credentials` item named by the connection's UUID. Nothing new in
   `~/.codex` or `settings.json`.
4. Quick AI and AI Chat: the Codex (ChatGPT) models are in the picker, with the levels the catalog
   gives. A reply streams, its thinking folds under "Thought for Ns", and Usage counts its tokens.
5. An agent chat on a Codex (ChatGPT) model: a task with tool calls runs several rounds without a
   400. A run of Codex CLI chats (the installed Codex route) still works.
6. After a reply: the connection page shows the limits with "As of …", or "No limits yet" if the
   route sent none. Settings → AI → Usage shows the Codex limits row. Activity Monitor and `lsof`
   show no request while Settings stays open.
7. Leave the Mac for over an hour and send again: the first request refreshes silently. Sign Out:
   the page shows Not signed in, and the next request says to sign in with ChatGPT.
8. Remove the connection: its Keychain item and its entry in `CodexPlan/limits.json` are gone.
