import { pathToFileURL } from "node:url";
import { bootConfig, createHarness } from "./test.mjs";

// The extension-runtime fixes this fork ports from sermelipharo/tinycast-space.
export async function runForkFixtures(check) {
  const requests = [];
  const harness = createHarness({
    stubs: {
      "fetch.request": async ([spec]) => {
        requests.push(spec);
        await new Promise((resolve) => setTimeout(resolve, 10));
        return { status: 200, statusText: "OK", headers: { "x-reply": "yes" }, url: spec.url,
          bodyBase64: Buffer.from("pong").toString("base64") };
      },
    },
  });
  harness.boot(bootConfig());
  harness.start("fork", "globalThis.probe = { require }; module.exports.default = () => {};",
    "/fork.js", "/", "no-view", {});
  const evaluate = (expression) => {
    try {
      return harness.call(`(() => { const { require } = probe; return ${expression}; })()`);
    } catch (error) {
      return String(error);
    }
  };

  try {
    const query = evaluate(
      'require("querystring").stringify({ a: undefined, b: null, c: NaN, d: 1, e: [true, undefined] })');
    check("querystring.stringify coerces like Node", query === "a=&b=&c=&d=1&e=true&e=", query);

    const blobs = evaluate(`[
      require("buffer").Blob === globalThis.Blob, require("node:buffer").File === globalThis.File,
      new (class extends require("buffer").Blob {})(["hi"]).size,
    ].join()`);
    check("buffer re-exports Blob and File, and Blob subclasses", blobs === "true,true,2", blobs);

    harness.call(`globalThis.dispatchUndici = (options, abortWhen) => new Promise((resolve) => {
      const events = [];
      globalThis[Symbol.for("undici.globalDispatcher.1")].dispatch(options, {
        onConnect(abort) {
          events.push("connect");
          if (abortWhen === "connect") abort();
          if (abortWhen === "flight") setTimeout(() => abort(), 3);
        },
        onHeaders(status, raw) { events.push(\`headers \${status} \${raw.map(String).join("=")}\`); },
        onData(chunk) { events.push(\`data \${chunk.toString()}\`); },
        onComplete() { events.push("complete"); resolve(events.join("|")); },
        onError(error) { events.push(\`error \${error.name}\`); resolve(events.join("|")); },
      });
    })`);
    const post = { origin: "https://x.test", path: "/p?q=1", method: "POST", headers: { a: "1" }, body: "hi" };
    const replayed = await harness.call(`dispatchUndici(${JSON.stringify(post)})`);
    const [sent] = requests;
    check("undici's global dispatcher sends through the fetch bridge",
      sent?.url === "https://x.test/p?q=1" && sent.method === "POST" && sent.headers.a === "1"
        && Buffer.from(sent.bodyBase64, "base64").toString() === "hi", JSON.stringify(sent));
    check("undici's handler sees headers, data and completion in order",
      replayed === "connect|headers 200 x-reply=yes|data pong|complete", replayed);
    const refused = await harness.call(`dispatchUndici(${JSON.stringify(post)}, "connect")`);
    check("an abort on connect sends nothing and reports one error",
      refused === "connect|error AbortError" && requests.length === 1, `${refused} ${requests.length}`);
    const cancelled = await harness.call(`dispatchUndici(${JSON.stringify(post)}, "flight")`);
    await new Promise((resolve) => setTimeout(resolve, 30));
    check("an abort in flight delivers no response",
      cancelled === "connect|error AbortError" && requests.length === 2, `${cancelled} ${requests.length}`);

    const probes = evaluate(`(() => {
      const { Readable, isDisturbed, isErrored } = require("stream");
      const readable = new Readable({ read() {} });
      readable.push("x");
      const before = isDisturbed(readable);
      readable.read();
      readable.destroy(new Error("gone"));
      return [before, isDisturbed(readable), isErrored(readable)].join();
    })()`);
    check("stream answers undici's state probes", probes === "false,true,true", probes);
  } finally {
    harness.stop("fork");
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  let failures = 0;
  await runForkFixtures((label, condition, detail) => {
    console.log(`${condition ? "✓" : "✗"} ${label}${condition ? "" : ` — ${detail}`}`);
    if (!condition) failures++;
  });
  process.exitCode = failures ? 1 : 0;
}
