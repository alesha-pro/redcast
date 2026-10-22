// Raycast's AI namespace, answered by the model chosen in Settings → Extensions → AI.

import { EventEmitter } from "../events.js";
import { hostCall } from "../host.js";
import { registerAccess, unsupported } from "./system.js";

// Every model routes to the one the user chose, so one honest entry stands for them all.
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
async function complete(prompt, signal, emitter) {
  throwIfAborted(signal);
  const id = await hostCall("ai", "start", [{ prompt: String(prompt ?? "") }]);
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
      emitter.emit("data", chunk);
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

function ask(prompt, options) {
  const emitter = new EventEmitter();
  const answer = complete(prompt, options?.signal, emitter);
  for (const name of ["on", "once", "off", "addListener", "removeListener"]) {
    answer[name] = (...args) => (emitter[name](...args), answer);
  }
  return answer;
}

export const AI = {
  ask,
  // Extension model providers are not surfaced, so there is nothing to refresh.
  refreshModels: async () => {},
  experimental_decide: () => unsupported("AI.experimental_decide"),
  Model,
  Creativity: Object.freeze({}),
};

registerAccess(AI, "ai");
