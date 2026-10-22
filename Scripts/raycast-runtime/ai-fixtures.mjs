import { pathToFileURL } from "node:url";
import { bootConfig, createHarness } from "./test.mjs";

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
// test.mjs settles a rejection with its message JSON-encoded, where Swift sends it bare.
const bare = (message) => message.replace(/^"(.*)"$/, "$1");

// A scripted host: each test sets how `ai.start` and `ai.read` answer, and every call is recorded.
function scriptedHarness() {
  const calls = [];
  let script = {};
  const cancelled = new Set();
  const waiters = new Map();
  const harness = createHarness({
    stubs: {
      "ai.start": async ([request]) => {
        calls.push(`start ${request.prompt}`);
        return script.start ? script.start(request) : 1;
      },
      "ai.read": async ([id]) => {
        calls.push(`read ${id}`);
        return script.read(id);
      },
      "ai.cancel": async ([id]) => {
        calls.push(`cancel ${id}`);
        cancelled.add(id);
        waiters.get(id)?.();
        return null;
      },
    },
  });
  // Stands in for a read that waits on the model until the stream is cancelled.
  const pending = (id) =>
    cancelled.has(id)
      ? Promise.reject(new Error("CancellationError"))
      : new Promise((_, reject) => waiters.set(id, () => reject(new Error("CancellationError"))));
  return {
    harness,
    calls,
    pending,
    script: (next) => {
      script = next;
      calls.length = 0;
    },
  };
}

function chunks(id, ...parts) {
  let index = 0;
  return (readID) => (readID === id && index < parts.length ? parts[index++] : null);
}

export async function runAIFixtures(check) {
  console.log("\n▶ AI.ask and environment.canAccess(AI)");
  const { harness, calls, pending, script } = scriptedHarness();
  harness.boot(bootConfig());
  const probe = `
    const api = require("@raycast/api");
    globalThis.probe = { AI: api.AI, environment: api.environment, BrowserExtension: api.BrowserExtension };
    module.exports.default = () => {};`;
  const run = (body) => harness.call(`(async () => { const { AI, environment } = probe; ${body} })()`);

  try {
    harness.start("plain", probe, "/ai.js", "/", "no-view", {});
    const denied = await run("return [environment.canAccess(AI), environment.canAccess(probe.BrowserExtension)].join()");
    harness.stop("plain");
    harness.start("granted", probe, "/ai.js", "/", "no-view", { ai: { access: true } });
    const granted = await run(
      "return [environment.canAccess(AI), environment.canAccess(probe.BrowserExtension), environment.canAccess()].join()");
    check("canAccess(AI) follows the launch context's ai.access", denied === "false,false" && granted === "true,false,false",
      `${denied} / ${granted}`);

    script({ start: () => 7, read: chunks(7, "Hel", "lo") });
    const streamed = await run(`
      const seen = [];
      const text = await AI.ask("hi").on("data", (chunk) => seen.push(chunk));
      return JSON.stringify([text, seen]);`);
    check("AI.ask resolves the whole answer and emits each chunk", streamed === '["Hello",["Hel","lo"]]', streamed);
    check("the prompt crosses alone, and reads stop at the end",
      calls.join("|") === "start hi|read 7|read 7|read 7", calls.join("|"));

    script({ start: () => 8, read: chunks(8, "a", "b") });
    const late = await run(`
      const answer = AI.ask("late");
      await Promise.resolve();
      const seen = [];
      const same = answer.on("data", (chunk) => seen.push(chunk)) === answer && answer instanceof Promise;
      return [await answer, seen.join(""), same].join();`);
    check("a listener attached after the call gets every chunk, and .on returns the promise", late === "ab,ab,true", late);

    script({ start: () => 9, read: () => Promise.reject(new Error("boom")) });
    const failed = await run(`try { await AI.ask("x"); return "resolved"; } catch (error) { return error.message; }`);
    check("a failed read rejects with its message", bare(failed) === "boom", failed);

    script({ start: () => Promise.reject(new Error("This extension isn't allowed to use AI.")), read: () => null });
    const refused = await run(`try { await AI.ask("x"); return "resolved"; } catch (error) { return error.message; }`);
    check("a refused start rejects with its message and never reads",
      bare(refused) === "This extension isn't allowed to use AI." && !calls.some((call) => call.startsWith("read")),
      `${refused} ${calls.join("|")}`);

    let reads = 0;
    script({ start: () => 10, read: (id) => (reads++ === 0 ? "Hel" : pending(id)) });
    const aborted = await run(`
      const controller = new AbortController();
      const seen = [];
      try {
        await AI.ask("x", { signal: controller.signal }).on("data", (chunk) => (seen.push(chunk), controller.abort()));
        return "resolved";
      } catch (error) {
        return error.name + " " + seen.join();
      }`);
    check("an abort cancels the stream and rejects with AbortError",
      aborted === "AbortError Hel" && calls.includes("cancel 10"), `${aborted} ${calls.join("|")}`);

    script({ read: () => null });
    const before = harness.state.hostCalls.length;
    const preAborted = await run(`
      try { await AI.ask("x", { signal: AbortSignal.abort() }); return "resolved"; } catch (error) { return error.name; }`);
    check("a signal aborted beforehand makes no host call",
      preAborted === "AbortError" && harness.state.hostCalls.length === before, preAborted);

    script({ start: () => wait(20).then(() => 13), read: chunks(13, "late") });
    const abortedWhileAsking = await run(`
      const controller = new AbortController();
      const answer = AI.ask("x", { signal: controller.signal });
      await Promise.resolve();
      controller.abort();
      try { await answer; return "resolved"; } catch (error) { return error.name; }`);
    check("an abort while ai.start is pending cancels the id it returns and never reads",
      abortedWhileAsking === "AbortError" && calls.includes("cancel 13") && !calls.includes("read 13"),
      `${abortedWhileAsking} ${calls.join("|")}`);

    script({ start: () => 11, read: pending });
    const timedOut = await run(`
      try { await AI.ask("x", { signal: AbortSignal.timeout(5) }); return "resolved"; } catch (error) { return error.name; }`);
    check("AbortSignal.timeout rejects with TimeoutError and cancels", timedOut === "TimeoutError" && calls.includes("cancel 11"),
      `${timedOut} ${calls.join("|")}`);

    script({ start: () => 12, read: chunks(12, "a") });
    const thrown = await run(`
      try { await AI.ask("x").on("data", () => { throw new Error("listener"); }); return "resolved"; } catch (error) { return error.message; }`);
    check("a throwing listener rejects the answer and cancels the stream", thrown === "listener" && calls.includes("cancel 12"),
      `${thrown} ${calls.join("|")}`);

    const model = await run(`
      return JSON.stringify([AI.Model["OpenAI_GPT-4o"], Object.entries(AI.Model), typeof AI.Model.toString]);`);
    check("AI.Model reads any name back and lists one entry", model === '["OpenAI_GPT-4o",[["Tinycast","tinycast"]],"function"]', model);

    const extras = await run(`
      const refreshed = await AI.refreshModels();
      try { await AI.experimental_decide({}); return "decided"; } catch (error) { return String(refreshed) + " " + error.message; }`);
    check("refreshModels resolves and experimental_decide is unsupported",
      extras.startsWith("undefined AI.experimental_decide is not supported"), extras);
    harness.stop("granted");

    await useAIPattern(check);
  } finally {
    harness.stop("plain");
    harness.stop("granted");
  }
}

// useAI's shape inlined: each run aborts the previous one, clears, then appends every chunk.
async function useAIPattern(check) {
  const { harness, calls, pending, script } = scriptedHarness();
  harness.boot(bootConfig());
  script({
    start: ({ prompt }) => (prompt === "first" ? 1 : 2),
    read: (() => {
      const second = chunks(2, "sec", "ond");
      let firstRead = false;
      return (id) => (id === 2 ? second(id) : firstRead ? pending(id) : ((firstRead = true), "fir"));
    })(),
  });
  harness.start("view", `
    const React = require("react");
    const { AI, Detail } = require("@raycast/api");
    module.exports.default = function Command() {
      const [prompt, setPrompt] = React.useState("first");
      const [data, setData] = React.useState("");
      const abortable = React.useRef();
      React.useEffect(() => {
        abortable.current?.abort();
        abortable.current = new AbortController();
        setData("");
        const stream = AI.ask(prompt, { signal: abortable.current.signal });
        stream.on("data", (chunk) => {
          setData((text) => text + chunk);
          if (prompt === "first") setPrompt("second");
        });
        stream.catch(() => {});
      }, [prompt]);
      return React.createElement(Detail, { markdown: data });
    };`, "/view.js", "/", "view", { ai: { access: true } });
  for (let tries = 0; tries < 50 && findMarkdown(harness.state.trees.at(-1)) !== "second"; tries++) await wait(10);
  await wait(30);
  const markdown = findMarkdown(harness.state.trees.at(-1));
  check("useAI's abort-then-ask renders only the newest answer",
    markdown === "second" && calls.includes("cancel 1") && !harness.state.failures.length,
    `${markdown} ${calls.join("|")} ${harness.state.failures.join("|")}`);
  harness.stop("view");
}

function findMarkdown(tree) {
  const stack = [...(tree?.children ?? [])];
  while (stack.length) {
    const node = stack.shift();
    if (node.type === "Detail") return node.props.markdown;
    stack.push(...(node.children ?? []));
  }
  return undefined;
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  let failures = 0;
  await runAIFixtures((label, condition, detail) => {
    console.log(`${condition ? "✓" : "✗"} ${label}${condition ? "" : ` — ${detail}`}`);
    if (!condition) failures++;
  });
  process.exitCode = failures ? 1 : 0;
}
