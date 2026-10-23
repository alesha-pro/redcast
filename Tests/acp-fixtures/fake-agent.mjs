// A scripted ACP agent for acp-test: newline-delimited JSON-RPC on stdio, no dependencies.
import readline from "node:readline";
import { spawn } from "node:child_process";

// `config` sends config options, as claude-agent-acp and codex-acp do; else the older shapes.
const variant = process.argv[2] === "config" ? "config" : "legacy";
// `refuse-model` turns every model switch down, as a busy or offline adapter would.
const refusesModel = process.argv.includes("refuse-model");
const sessions = new Map();
let nextSession = 1;
let nextRequest = 1000;
const waiting = new Map();
const state = { loads: [], cancels: [], news: 0, modes: [], grandchild: null };
const commands = [
  { name: "review", description: "Review the changes", input: { hint: "what to review" } },
  { name: "/compact", description: "Summarise\nthe conversation", input: null },
  { name: "bad name", description: "never offered" },
];
const modes = {
  currentModeId: "default",
  availableModes: [
    { id: "default", name: "Default", description: "Asks first" },
    { id: "plan", name: "Plan", description: "Plans before acting" },
  ],
};

const legacyModels = [
  { modelId: "m-small", name: "Small", description: "Quick" },
  { modelId: "m-large", name: "Large" },
];
// Each model has its own levels, so a switch can strand a remembered one, as in codex-acp.
const models = {
  small: { name: "Small", efforts: ["low", "medium"] },
  large: { name: "Large", efforts: ["low", "medium", "high"] },
  huge: { name: "Huge", efforts: ["medium", "high", "max"] },
};

function configOptions(session) {
  return [
    {
      id: "mode", name: "Mode", category: "mode", type: "select", currentValue: session.mode,
      options: modes.availableModes.map((m) => ({ value: m.id, name: m.name, description: m.description })),
    },
    {
      id: "model", name: "Model", category: "model", type: "select", currentValue: session.model,
      options: [
        { group: "fast", name: "Fast", options: [{ value: "small", name: "Small", description: "Quick" }] },
        { group: "smart", name: "Smart", options: [{ value: "large", name: "Large" }, { value: "huge", name: "Huge" }] },
      ],
    },
    {
      id: "effort", name: "Effort", category: "thought_level", type: "select", currentValue: session.effort,
      options: models[session.model].efforts.map((e) => ({ value: e, name: e[0].toUpperCase() + e.slice(1) })),
    },
    {
      id: "fast", name: "Fast mode", category: "model_config", type: "select", currentValue: session.fast,
      options: [{ value: "off", name: "Off" }, { value: "on", name: "On" }],
    },
    { id: "beta", name: "Beta", type: "boolean", currentValue: false },
  ];
}

function opened(sessionId, session) {
  if (variant === "config") return { modes: { ...modes, currentModeId: session.mode }, configOptions: configOptions(session) };
  return { modes, models: { availableModels: legacyModels, currentModelId: session.model } };
}

function fresh(cwd, servers, turns) {
  return variant === "config"
    ? { cwd, turns, servers, model: "small", effort: "low", mode: "default", fast: "off", sets: [] }
    : { cwd, turns, servers, model: "m-small", sets: [] };
}

function send(message) {
  process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...message }) + "\n");
}

function update(sessionId, update) {
  send({ method: "session/update", params: { sessionId, update } });
}

function ask(method, params) {
  const id = nextRequest++;
  send({ id, method, params });
  return new Promise((resolve) => waiting.set(id, resolve));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function prompt(id, params) {
  const { sessionId, prompt } = params;
  const session = sessions.get(sessionId);
  session.turns += 1;
  const text = prompt.filter((b) => b.type === "text").map((b) => b.text).join("\n");
  const images = prompt.filter((b) => b.type === "image").length;

  if (text.includes("SLOW")) {
    update(sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Working" } });
    session.cancelled = false;
    for (let i = 0; i < 100 && !session.cancelled; i++) await sleep(50);
    send({ id, result: { stopReason: session.cancelled ? "cancelled" : "end_turn" } });
    return;
  }
  if (text.includes("LEAVEPLAN")) {
    update(sessionId, { sessionUpdate: "current_mode_update", currentModeId: "default" });
    send({ id, result: { stopReason: "end_turn" } });
    return;
  }
  if (text.includes("SWITCHMODEL")) {
    session.model = "huge";
    session.effort = "high";
    update(sessionId, { sessionUpdate: "config_option_update", configOptions: configOptions(session) });
    send({ id, result: { stopReason: "end_turn" } });
    return;
  }
  if (text.includes("REFUSE")) {
    send({ id, result: { stopReason: "refusal" } });
    return;
  }
  const first = prompt[0]?.type === "text" ? prompt[0].text : "";
  if (first.startsWith("/")) {
    const context = text.includes("Context from Tinycast") ? "with context" : "without context";
    update(sessionId, {
      sessionUpdate: "agent_message_chunk",
      content: { type: "text", text: `ran ${first}; ${context}; blocks ${prompt.length}` },
    });
    send({ id, result: { stopReason: "end_turn" } });
    return;
  }
  if (text.includes("DIFF")) {
    const diff = { type: "diff", path: "/tmp/a.txt", oldText: "keep\nold\nkeep 2", newText: "keep\nnew\nkeep 2" };
    update(sessionId, {
      sessionUpdate: "tool_call", toolCallId: "call_d", title: "Edit a.txt", kind: "edit", status: "in_progress",
      content: [diff],
    });
    update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "call_d", content: [diff] });
    update(sessionId, { sessionUpdate: "tool_call_update", toolCallId: "call_d", status: "completed" });
    update(sessionId, { sessionUpdate: "tool_call", toolCallId: "call_x", title: "npm test", kind: "execute", status: "in_progress" });
    update(sessionId, {
      sessionUpdate: "tool_call_update", toolCallId: "call_x", status: "completed",
      content: [{ type: "content", content: { type: "text", text: "```console\n\u001b[32mok\u001b[0m 3 tests\n```" } }],
    });
    send({ id, result: { stopReason: "end_turn" } });
    return;
  }

  update(sessionId, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Thinking it over." } });
  update(sessionId, {
    sessionUpdate: "plan",
    entries: [{ content: "Look", priority: "high", status: "completed" }, { content: "Edit", priority: "high", status: "pending" }],
  });
  update(sessionId, {
    sessionUpdate: "tool_call", toolCallId: "call_1", title: "Edit notes.md", kind: "edit", status: "pending",
    rawInput: { path: "/tmp/notes.md" },
  });
  const answer = await ask("session/request_permission", {
    sessionId,
    toolCall: {
      toolCallId: "call_1", title: "Edit notes.md", kind: "edit",
      content: [{ type: "diff", path: "/tmp/notes.md", oldText: "old", newText: "new" }],
    },
    options: [
      { optionId: "reject", name: "Reject", kind: "reject_once" },
      { optionId: "always", name: "Always allow", kind: "allow_always" },
      { optionId: "once", name: "Allow", kind: "allow_once" },
    ],
  });
  const chosen = answer.outcome.outcome === "selected" ? answer.outcome.optionId : "cancelled";
  update(sessionId, {
    sessionUpdate: "tool_call_update", toolCallId: "call_1",
    status: chosen === "reject" || chosen === "cancelled" ? "failed" : "completed",
  });
  update(sessionId, { sessionUpdate: "tool_call", toolCallId: "call_2", title: "Never finished", kind: "read" });
  update(sessionId, { sessionUpdate: "usage_update", used: 1200, size: 200000, cost: { amount: 0.01, currency: "USD" } });
  const context = text.includes("Context from Tinycast") ? "with context" : "without context";
  const earlier = text.split("## Earlier in this conversation")[1];
  const history = earlier === undefined
    ? "no history"
    : `with history of ${(earlier.match(/^(User|Assistant): /gm) ?? []).length} turns`;
  const briefed = text.includes("# Running unattended") ? "; briefed" : "";
  const on = variant === "config" ? `${session.model}/${session.effort}/${session.mode}/${session.fast}` : session.model;
  const sets = session.sets.join(",") || "none";
  update(sessionId, {
    sessionUpdate: "agent_message_chunk",
    content: { type: "text", text: `turn ${session.turns} in ${session.cwd}; ${chosen}; ${context}; ${history}; images ${images}; servers ${session.servers}${briefed}; on ${on}; sets ${sets}` },
  });
  send({ id, result: { stopReason: "end_turn" } });
}

const input = readline.createInterface({ input: process.stdin });
input.on("line", (line) => {
  if (!line.trim()) return;
  const message = JSON.parse(line);
  if (message.method === undefined) {
    const resolve = waiting.get(message.id);
    if (resolve) { waiting.delete(message.id); resolve(message.result); }
    return;
  }
  const { id, method, params } = message;
  switch (method) {
    case "initialize":
      send({
        id,
        result: {
          protocolVersion: 1,
          agentCapabilities: { loadSession: true, promptCapabilities: { image: true, embeddedContext: true } },
          agentInfo: { name: "fake", title: "Fake Agent", version: "1" },
          authMethods: [],
        },
      });
      break;
    case "session/new": {
      const sessionId = `sess_${nextSession++}`;
      state.news += 1;
      const session = fresh(params.cwd, params.mcpServers.length, 0);
      sessions.set(sessionId, session);
      send({ id, result: { sessionId, ...opened(sessionId, session) } });
      // After the reply, as claude-agent-acp does: the list can beat the client's own bookkeeping.
      setTimeout(() => update(sessionId, { sessionUpdate: "available_commands_update", availableCommands: commands }), 0);
      break;
    }
    case "session/load":
      state.loads.push(params.sessionId);
      if (params.sessionId.startsWith("gone_")) {
        send({ id, error: { code: -32002, message: "Session not found" } });
      } else {
        const session = fresh(params.cwd, params.mcpServers.length, 10);
        sessions.set(params.sessionId, session);
        update(params.sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "REPLAYED" } });
        send({ id, result: opened(params.sessionId, session) });
      }
      break;
    case "session/set_mode":
      state.modes.push(`${params.sessionId}:${params.modeId}`);
      sessions.get(params.sessionId)?.sets.push(`mode=${params.modeId}`);
      send({ id, result: {} });
      break;
    case "session/set_model": {
      const session = sessions.get(params.sessionId);
      if (variant === "config" || !legacyModels.some((m) => m.modelId === params.modelId)) {
        send({ id, error: { code: -32601, message: "Method not found" } });
        break;
      }
      session.model = params.modelId;
      session.sets.push(`model=${params.modelId}`);
      send({ id, result: {} });
      break;
    }
    case "session/set_config_option": {
      const session = sessions.get(params.sessionId);
      const option = variant === "config" ? configOptions(session).find((o) => o.id === params.configId) : undefined;
      const values = (option?.options ?? []).flatMap((o) => o.options ?? [o]).map((o) => o.value);
      if (refusesModel && params.configId === "model") {
        send({ id, error: { code: -32603, message: "Internal error" } });
        break;
      }
      if (!values.includes(params.value)) {
        send({ id, error: { code: -32602, message: "Invalid params" } });
        break;
      }
      session.sets.push(`${params.configId}=${params.value}`);
      session[params.configId] = params.value;
      if (params.configId === "model" && !models[session.model].efforts.includes(session.effort)) session.effort = "medium";
      if (params.configId === "mode") update(params.sessionId, { sessionUpdate: "current_mode_update", currentModeId: params.value });
      send({ id, result: { configOptions: configOptions(session) } });
      break;
    }
    case "session/prompt":
      prompt(id, params);
      break;
    case "session/cancel": {
      state.cancels.push(params.sessionId);
      const session = sessions.get(params.sessionId);
      if (session) session.cancelled = true;
      break;
    }
    case "_fake/spawn": {
      // A descendant that ignores SIGTERM, as a stuck tool would.
      const child = spawn(process.execPath, ["-e", "process.on('SIGTERM',()=>{});setInterval(()=>{},1000)"], { stdio: "ignore" });
      state.grandchild = child.pid;
      send({ id, result: { pid: child.pid } });
      break;
    }
    case "_fake/state":
      send({ id, result: state });
      break;
    default:
      if (id !== undefined) send({ id, error: { code: -32601, message: `no ${method}` } });
  }
});
