// A scripted ACP agent for acp-test: newline-delimited JSON-RPC on stdio, no dependencies.
import readline from "node:readline";
import { spawn } from "node:child_process";

const sessions = new Map();
let nextSession = 1;
let nextRequest = 1000;
const waiting = new Map();
const state = { loads: [], cancels: [], news: 0, modes: [], grandchild: null };
const modes = {
  currentModeId: "default",
  availableModes: [
    { id: "default", name: "Default", description: "Asks first" },
    { id: "plan", name: "Plan", description: "Plans before acting" },
  ],
};

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
  if (text.includes("REFUSE")) {
    send({ id, result: { stopReason: "refusal" } });
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
  const history = text.includes("Earlier in this conversation") ? "with history" : "no history";
  const briefed = text.includes("# Running unattended") ? "; briefed" : "";
  update(sessionId, {
    sessionUpdate: "agent_message_chunk",
    content: { type: "text", text: `turn ${session.turns} in ${session.cwd}; ${chosen}; ${context}; ${history}; images ${images}; servers ${session.servers}${briefed}` },
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
      sessions.set(sessionId, { cwd: params.cwd, turns: 0, servers: params.mcpServers.length });
      send({ id, result: { sessionId, modes } });
      break;
    }
    case "session/load":
      state.loads.push(params.sessionId);
      if (params.sessionId.startsWith("gone_")) {
        send({ id, error: { code: -32002, message: "Session not found" } });
      } else {
        sessions.set(params.sessionId, { cwd: params.cwd, turns: 10, servers: params.mcpServers.length });
        update(params.sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "REPLAYED" } });
        send({ id, result: {} });
      }
      break;
    case "session/set_mode":
      state.modes.push(`${params.sessionId}:${params.modeId}`);
      send({ id, result: {} });
      break;
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
