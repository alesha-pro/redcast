# Quick AI tools

Quick AI reaches the same tools as AI Chat without opening it. **⌘K → Web Search** turns on the
setting the AI Chat composer's **+** menu toggles, so an API model can `web_search` and then
`read_page` a result. **Settings → AI → Agents → Quick AI answers with** picks an agent on the
chat's model, and Quick AI's new chats then run on that agent's own harness, with its tools, folder,
instructions and permissions; **⌘K → Answer with** switches it for the chat in front. And every chat
is now told the local time, and a plain chat which tools it has, or in one line where Web Search is
turned on, instead of refusing a question about the weather. The feature is this fork's, in
`Features/QuickAITools/` plus the lines that wire it into `AIChatCoordinator`, `QuickAICoordinator`,
`AIScreen`, `AgentCoordinator`, `AgentsSettingsSection`, `AppSettingsKey`, `SettingsBackupCoverage`
and `SettingsSearchCatalog`.

## Invariants

- **One switch, three places.** ⌘K → Web Search writes `aiWebSearch`, the setting the composer's
  **+** menu and Settings → AI → Chat toggle, and a HUD says which way it went, since Quick AI has
  no pill to show it. The row shows where the **+** menu offers Web Search to a chat without an
  agent (`ChatToolPolicy.offersSearchSwitch`): a route that searches, an API model with tool calling
  or Codex. An agent's Web family decides for its own chat.
- **Quick AI's agent is Settings' pick until the chat speaks, then the chat's own.**
  `AgentCoordinator.agent(for:)` resolves through `ChatToolPolicy.agent`: a chat's own binding wins;
  Quick AI's chat with no message yet takes `aiQuickAIAgent` unless ⌘K said No Agent for that chat
  (`quickAIDeclined`, in memory, by chat id). Its first send, and ⌘J, bind it through `setAgent`, so
  later turns, AI Chat and the history keep it, and a later change in Settings never moves a chat
  that has spoken. A chat Quick AI resumes without an agent stays plain; AI Chat's window never
  takes it. Everything that asks `agent(for:)` — the route, the agent's prompt, the model the chat
  runs on, the capabilities and the context card — sees the agent before the first message, so the
  header's model is the agent's and the first turn is already the agent's.
- **Only agents on the chat's model.** Quick AI offers agents whose `runtime` is nil, so a turn runs
  `AgentLoopProvider` over the agent's toolset exactly as in AI Chat, its consent dialogs included.
  ACP agents are not offered: Quick AI's header holds the chat model's and reasoning pickers, which
  an ACP agent ignores, while its own model, reasoning and mode pickers and its slash commands live
  only in AI Chat's composer; and an ACP agent is a CLI process tree (Claude Code's is about 380 MB)
  that stays up for two minutes after every turn and can take minutes to start cold, the opposite of
  a quick surface with nothing resident. A chat opened from history that already has one keeps it,
  and ⌘K lists it there so it can be switched off. Settings' pick reads as No Agent once its agent
  is deleted or moved onto its own CLI.
- **The agent shows where it answers.** Quick AI sets `agentChatBadge` as the window does, so its
  tile, name and folder head the transcript, and `QuickAIAgentHeader` puts the same line over the
  empty chat.
- **The briefing ends the shared prompt, under its switch.** AIChatCoordinator's
  `instructions(for:scopedTo:)` appends `ChatBriefing.text` to `AIInstructions.compose`, so Send a
  system prompt off sends none of it, and an agent's prompt still follows it. Every chat gets the
  local weekday, date, quarter hour, zone and UTC offset. A plain chat on a route that calls tools
  also gets the turn's tools by name (`@server` narrowing included, 24 at most); with `web_search`
  among them, live facts (weather, prices, news, schedules) go through `web_search` and then
  `read_page` on the best result, and a page lacking the figures sends it on to another result.
  Without it, where the switch applies, the model says in one line where Web Search is turned on (⌘K
  in Quick AI, the **+** menu in AI Chat), naming the item as the app's language spells it, and
  invents no current figures. An agent's chat gets only the time: its own prompt describes its
  tools.
- **To the quarter hour, so the cache keeps.** The instructions open every request, and a provider's
  prompt cache (Anthropic's and OpenRouter's for Claude, the automatic prefix caches elsewhere) is
  lost whenever they change, so the time is a fifteen-minute window (`ChatBriefing.clockStep`)
  rather than the minute: the prompt changes four times an hour, not on every turn. Model-facing
  text is English, its weekday from an `en_US_POSIX` calendar.
- **Nothing resident.** `QuickAISettingsStore` reads one default the first time an agent is
  resolved; the ⌘K rows are built when the menu opens; the briefing is a string built per send. No
  timer, no file, no network but the turn's own.
- **The setting never travels.** `aiQuickAIAgent` names an agent on this Mac and lends it Quick AI's
  questions, so it is excluded from backups and has no `settings.json` key, as `voiceAskAgent`. The
  previous build ignores the key.

## What Quick AI offers

| Quick AI chat | Web Search | ⌘K Web Search | Sent to the model | Briefing after the time |
| --- | --- | --- | --- | --- |
| No agent, API model | off | shown | MCP tools, if any | where to turn Web Search on |
| No agent, API model | on | shown, checked | `web_search`, `read_page`, MCP tools | the tools, and search then read |
| Agent on the chat's model | either | hidden | the agent's toolset and MCP | nothing: the agent's prompt follows |
| No agent, Codex | either | shown | Codex's own search while on | where to turn it on, while off |
| Apple Intelligence | — | hidden | nothing | nothing |

## Layout

| File | Holds |
| --- | --- |
| `Model/ChatToolPolicy.swift` | The rules: the switch, the web tools, the hint, whether tools are listed, which agent answers |
| `Model/ChatBriefing.swift` | The prompt's last lines: the clock, the tools, the live-facts rule, the switch's place |
| `Settings/QuickAISettingsStore.swift` | `aiQuickAIAgent` in `UserDefaults` |
| `Settings/QuickAIAgentRow.swift` | Quick AI answers with, in Settings → AI → Agents |
| `UI/QuickAIAgents.swift` | `AgentCoordinator`'s Quick AI part: the agents offered, Settings' pick, binding, ⌘K's choice |
| `UI/ChatToolFacts.swift` | `AIChatCoordinator`'s facts for the policy, the briefing for a turn, the ⌘K toggle |
| `UI/QuickAIToolsMenu.swift` | The ⌘K rows: Web Search, then Answer with |
| `UI/QuickAIAgentHeader.swift` | The agent's line over an empty Quick AI chat |

## Manual sweep

1. Set an OpenRouter model as the default with Web search off and no agent. In Quick AI ask "какая
   погода в Москве?": the reply says in one line that ⌘K → Web Search turns searching on, and gives
   no current temperature.
2. ⌘K → Web Search: a HUD says Web search is on, the row is checked the next time ⌘K opens, and AI
   Chat's composer shows its Search pill. Ask again: a "Searched web · погода Москва" row, a "Web
   search · read_page" row on a result such as yandex.ru/pogoda, and the temperature with its
   source.
3. Ask "what time is it here?": the answer falls in the current quarter hour and names the zone.
4. Settings → AI → Agents → Quick AI answers with → an agent. Open Quick AI: the agent's tile, name
   and folder head the empty chat and the model button shows the model it runs on. ⌘K has no Web
   Search row. Ask "what is in this folder?": the agent's tool rows run, and a change asks as its
   permissions say. ⌘J: AI Chat shows the chat with that agent picked.
5. ⌘N, then ⌘K → Answer with → No Agent: the header goes and the next question is a plain chat's. On
   a plain chat with messages, ⌘K → an agent: the header appears and the next turn is the agent's.
6. On Apple Intelligence, ⌘K offers no Web Search and the prompt points at no switch.
7. Search Settings for "Quick AI answers": it lands on the row. Delete the agent: the row reads No
   Agent and Quick AI answers plainly. Export a backup: `aiQuickAIAgent` is not in it.

Harness: `quick-ai-tools-test` (the clock across zones and quarter-hour edges, the briefing with and
without tools or search, the offering rules for Quick AI with Web Search on and off and with and
without an agent, Codex, the Claude command, the on-device model and AI Chat, which agent answers,
and the setting across launches). `agent-tools-test` and `web-search-test` hold the page reads.
