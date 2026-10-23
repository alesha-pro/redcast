// Raycast's AI namespace, answered by the model chosen in Settings → Extensions → AI.

import { EventEmitter } from "../events.js";
import { hostCall } from "../host.js";
import { registerAccess } from "./system.js";

// Any capitalised name reads back as itself; Swift reads its vendor, so no table ships here.
const Model = new Proxy(Object.freeze({ Tinycast: "tinycast" }), {
  get: (target, key) =>
    typeof key === "string" && /^[A-Z]/.test(key) ? (target[key] ?? key) : Reflect.get(target, key),
});

// A bundled AbortController may lack `throwIfAborted`, so read the signal by hand.
function throwIfAborted(signal) {
  if (!signal?.aborted) return;
  throw signal.reason ?? Object.assign(new Error("The operation was aborted."), { name: "AbortError" });
}

// Pull-based like `proc.read`: one read outstanding, so a fast model never floods the queue.
async function complete(request, signal, emitter) {
  throwIfAborted(signal);
  const id = await hostCall("ai", "start", [request]);
  const cancel = () => hostCall("ai", "cancel", [id]).catch(() => {});
  if (signal?.aborted) {
    cancel();
    throwIfAborted(signal);
  }
  signal?.addEventListener?.("abort", cancel);
  let text = "";
  try {
    for (let chunk; (chunk = await hostCall("ai", "read", [id])) != null; ) {
      throwIfAborted(signal);
      text += chunk;
      emitter?.emit("data", chunk);
    }
  } catch (error) {
    throwIfAborted(signal);
    // A throwing "data" listener leaves the answer streaming; a failed read already ended it.
    cancel();
    throw error;
  } finally {
    signal?.removeEventListener?.("abort", cancel);
  }
  throwIfAborted(signal);
  return text;
}

// A `{ id }` model is the extension's own provider, never surfaced, so only a name crosses.
function askRequest(prompt, options) {
  const request = { prompt: String(prompt ?? "") };
  if (typeof options?.model === "string") request.model = options.model;
  const creativity = options?.creativity;
  if (typeof creativity === "string" || typeof creativity === "number") request.creativity = creativity;
  return request;
}

function ask(prompt, options) {
  const emitter = new EventEmitter();
  const answer = complete(askRequest(prompt, options), options?.signal, emitter);
  for (const name of ["on", "once", "off", "addListener", "removeListener"]) {
    answer[name] = (...args) => (emitter[name](...args), answer);
  }
  return answer;
}

// No route returns logprobs, so the model states each probability and Raycast's shapes are rebuilt.
async function decide(input, options) {
  const questions = Object.entries(input?.questions ?? {});
  if (!questions.length) throw new TypeError("AI.experimental_decide needs at least one question.");
  for (const [key, question] of questions) {
    if (question?.type !== "noul" && !levels(question)?.length) {
      throw new TypeError(`Question "${key}" needs the type noul, choice or score, with its criteria.`);
    }
  }
  const state = typeof input.state === "string" ? input.state : JSON.stringify(input.state);
  const prompt = [
    "Judge the state below against each question. Reply with one JSON object and nothing else, with",
    'one key per question. For a "noul" question the value is {"p": the probability, 0 to 1, that its',
    'instructions hold}; for a "choice" question {"p": {each option: its probability}}; for a "score"',
    'question {"p": [the probability of each criterion, first to last]}. Each set sums to 1.',
    "",
    `Questions: ${JSON.stringify(input.questions)}`,
    "",
    `State: ${state ?? ""}`,
  ].join("\n");
  const text = await complete({ prompt, creativity: 0 }, options?.signal);
  let reply;
  try {
    reply = JSON.parse(text.slice(text.indexOf("{"), text.lastIndexOf("}") + 1));
  } catch {}
  if (!reply || typeof reply !== "object") {
    throw new Error("The model's answer was not the JSON a decision needs.");
  }
  return Object.fromEntries(
    questions.map(([key, question]) => [key, decision(question, reply[key]?.p ?? reply[key], key)]),
  );
}

// The keys a choice's or a score's probabilities are read by: each option, or each level's index.
function levels(question) {
  if (question?.type === "choice") return Object.keys(question.criteria ?? {});
  if (question?.type === "score") return Array.from(question.criteria ?? [], (_, index) => String(index));
}

function decision(question, value, key) {
  const missing = () => new Error(`The model's answer has no probabilities for "${key}".`);
  if (question.type === "noul") {
    const noul = Number(value);
    if (value == null || !Number.isFinite(noul)) throw missing();
    return { type: "noul", noul: Math.min(1, Math.max(0, noul)) };
  }
  const keys = levels(question);
  const raw = keys.map((level) => Math.max(0, Number(value?.[level]) || 0));
  const total = raw.reduce((sum, share) => sum + share, 0);
  if (!(total > 0)) throw missing();
  const shares = raw.map((share) => share / total);
  const best = shares.indexOf(Math.max(...shares));
  const probabilities = Object.fromEntries(keys.map((level, index) => [level, shares[index]]));
  if (question.type === "choice") {
    return { type: "choice", choice: keys[best], confidence: shares[best], probabilities };
  }
  return {
    type: "score",
    score: shares.reduce((sum, share, index) => sum + share * index, 0),
    confidence: shares[best],
    legend: Object.fromEntries(Array.from(question.criteria, (text, index) => [String(index), text])),
    probabilities,
  };
}

export const AI = {
  ask,
  // Extension model providers are not surfaced, so there is nothing to refresh.
  refreshModels: async () => {},
  experimental_decide: decide,
  Model,
  Creativity: Object.freeze({}),
};

registerAccess(AI, "ai");
