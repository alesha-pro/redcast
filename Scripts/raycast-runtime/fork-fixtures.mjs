import { pathToFileURL } from "node:url";
import { bootConfig, createHarness } from "./test.mjs";

// The extension-runtime fixes this fork ports from sermelipharo/tinycast-space.
export async function runForkFixtures(check) {
  const harness = createHarness();
  harness.boot(bootConfig());
  harness.start("fork", "globalThis.probe = { require }; module.exports.default = () => {};",
    "/fork.js", "/", "no-view", {});
  const evaluate = (expression) => harness.call(`(() => { const { require } = probe; return ${expression}; })()`);

  try {
    const query = evaluate(
      'require("querystring").stringify({ a: undefined, b: null, c: NaN, d: 1, e: [true, undefined] })');
    check("querystring.stringify coerces like Node", query === "a=&b=&c=&d=1&e=true&e=", query);
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
