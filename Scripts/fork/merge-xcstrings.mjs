#!/usr/bin/env node
// Three-way merge of a string catalog, key by key. Usage: see docs/fork-tooling.md or --help.
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { rebrand } from "./rebrand.mjs";
import { isMain, parse, serialize } from "./xcstrings.mjs";

const DEFAULT_PATH = "Tinycast/Resources/Localizable.xcstrings";

const same = (a, b) =>
  a === undefined ? b === undefined : b !== undefined && serialize(a) === serialize(b);

// The 3-way rule; `undefined` is "both changed it differently".
function pick(base, ours, theirs) {
  if (same(ours, theirs)) return { value: ours };
  if (same(ours, base)) return { value: theirs };
  if (same(theirs, base)) return { value: ours };
  return undefined;
}

const byCodePoint = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));

// Both sides changed one entry: merge its fields, and its languages one by one.
function mergeEntry(base, ours, theirs) {
  const languages = [];
  if (!(ours instanceof Map) || !(theirs instanceof Map)) return { value: ours, languages: ["*"] };
  const merged = new Map();
  const keys = [...new Set([...theirs.keys(), ...ours.keys()])].sort(byCodePoint);
  for (const key of keys) {
    const b = base instanceof Map ? base.get(key) : undefined;
    const perLanguage =
      key === "localizations" && ours.get(key) instanceof Map && theirs.get(key) instanceof Map;
    if (!perLanguage) {
      const chosen = pick(b, ours.get(key), theirs.get(key));
      if (!chosen) languages.push(key);
      const value = chosen ? chosen.value : ours.get(key);
      if (value !== undefined) merged.set(key, value);
      continue;
    }
    const localized = new Map();
    const codes = [...new Set([...ours.get(key).keys(), ...theirs.get(key).keys()])];
    codes.sort(byCodePoint);
    for (const code of codes) {
      const chosen = pick(b?.get(code), ours.get(key).get(code), theirs.get(key).get(code));
      if (!chosen) languages.push(code);
      const value = chosen ? chosen.value : ours.get(key).get(code);
      if (value !== undefined) localized.set(code, value);
    }
    merged.set(key, localized);
  }
  return { value: merged, languages };
}

// Theirs' order, with each key only ours has placed after its predecessor in ours.
function mergeStrings(base, ours, theirs, report) {
  const values = new Map();
  for (const key of new Set([...theirs.keys(), ...ours.keys()])) {
    const chosen = pick(base.get(key), ours.get(key), theirs.get(key));
    if (chosen) {
      if (chosen.value !== undefined) values.set(key, chosen.value);
      continue;
    }
    const entry = mergeEntry(base.get(key), ours.get(key), theirs.get(key));
    if (entry.languages.length > 0) report.conflicts.push({ key, languages: entry.languages });
    if (entry.value !== undefined) values.set(key, entry.value);
  }
  const order = [...theirs.keys()].filter((key) => values.has(key));
  const placed = new Set(order);
  const ourKeys = [...ours.keys()];
  ourKeys.forEach((key, index) => {
    if (placed.has(key) || !values.has(key)) return;
    const predecessor = order.indexOf(ourKeys[index - 1]);
    const position =
      index > 0 && predecessor >= 0
        ? predecessor + 1
        : order.findIndex((other) => byCodePoint(other, key) > 0);
    order.splice(position < 0 ? order.length : position, 0, key);
    placed.add(key);
  });
  for (const key of theirs.keys()) {
    if (!base.has(key) && !ours.has(key)) report.added++;
  }
  for (const key of base.keys()) {
    if (!values.has(key) && ours.has(key)) report.removed++;
  }
  return new Map(order.map((key) => [key, values.get(key)]));
}

// All three as the fork names the app, so a string it only renamed still takes upstream's edits.
function merge(...sides) {
  const rebranded = sides.map((side) => rebrand(side));
  const [base, ours, theirs] = rebranded.map((side) => side.catalog);
  const report = { conflicts: [], added: 0, removed: 0, renamed: [] };
  const merged = new Map();
  for (const key of new Set([...theirs.keys(), ...ours.keys()])) {
    if (key === "strings") {
      const strings = (catalog) => catalog.get("strings") ?? new Map();
      merged.set(key, mergeStrings(strings(base), strings(ours), strings(theirs), report));
      continue;
    }
    const chosen = pick(base.get(key), ours.get(key), theirs.get(key));
    if (!chosen) report.conflicts.push({ key: `(${key})`, languages: [] });
    const value = chosen ? chosen.value : ours.get(key);
    if (value !== undefined) merged.set(key, value);
  }
  // Upstream's new or changed strings the rename touched, for someone to read: one about upstream
  // itself belongs in rebrand.mjs's EXCLUDED.
  const strings = (catalog) => catalog.get("strings") ?? new Map();
  const [before, after, result] = [sides[0], sides[2], merged].map(strings);
  report.renamed = rebranded[2].changed.filter(
    (key) => result.has(key) && !same(before.get(key), after.get(key)));
  return { catalog: merged, report };
}

function git(...args) {
  try {
    return execFileSync("git", args, {
      encoding: "utf8",
      maxBuffer: 1 << 28,
      stdio: ["ignore", "pipe", "ignore"],
    });
  } catch {
    return undefined;
  }
}

// A conflict's three stages; else, during a merge git finished on its own, its three commits.
// git's line merge can be wrong for a catalog: an English value the fork derived from a key
// survives upstream rewording that key in place, now under the new key.
function sides(path) {
  const ours = git("show", `:2:${path}`);
  const theirs = git("show", `:3:${path}`);
  if (ours !== undefined || theirs !== undefined) return [git("show", `:1:${path}`), ours, theirs];
  const base = git("merge-base", "HEAD", "MERGE_HEAD")?.trim();
  if (!base) return [];
  return [base, "HEAD", "MERGE_HEAD"].map((revision) => git("show", `${revision}:${path}`));
}

function run(path) {
  const [base, ours, theirs] = sides(path);
  if (ours === undefined || theirs === undefined) {
    console.error(`✗ ${path} has neither conflict stages nor both sides of a merge in progress`);
    return 2;
  }
  let catalogs;
  try {
    catalogs = [base ?? "{}", ours, theirs].map(parse);
  } catch (error) {
    console.error(`✗ ${path}: ${error.message}`);
    return 2;
  }
  const { catalog, report } = merge(...catalogs);
  writeFileSync(path, serialize(catalog) + "\n");
  execFileSync("git", ["add", "--", path]);
  const review = report.conflicts.length;
  console.log(`+${report.added} upstream keys, -${report.removed} removed, ${review} need review`);
  const count = report.renamed.length;
  const noun = count === 1 ? "key" : "keys";
  if (count > 0) console.log(`renamed Tinycast in ${count} upstream ${noun}`);
  for (const key of report.renamed) console.log(`  ${JSON.stringify(key)}`);
  for (const { key, languages } of report.conflicts) {
    console.error(`${key}  (${languages.join(", ")})`);
  }
  return review > 0 ? 1 : 0;
}

const toMap = (value) =>
  value && typeof value === "object" && !Array.isArray(value)
    ? new Map(Object.entries(value).map(([key, item]) => [key, toMap(item)]))
    : value;

const unit = (value) => ({ stringUnit: { state: "translated", value } });

function selfTest() {
  let failures = 0;
  const expect = (condition, message) => {
    if (!condition) {
      failures++;
      console.error(`FAIL: ${message}`);
    }
  };
  const committed = readFileSync(DEFAULT_PATH, "utf8");
  expect(serialize(parse(committed)) + "\n" === committed, "the committed catalog round-trips");
  const layout = '{\n  "9" : {\n\n  },\n  "a" : [\n    1,\n    true\n  ]\n}';
  expect(serialize(parse('{"9":{},"a":[1,true]}')) === layout, "order and layout are Xcode's");

  const catalog = (strings) => toMap({ sourceLanguage: "en", strings, version: "1.0" });
  const base = catalog({
    Apple: { localizations: { de: unit("Apfel"), ru: unit("Яблоко") } },
    Banana: { localizations: { de: unit("Banane") } },
    Gone: { localizations: { de: unit("Weg") } },
    Kept: { localizations: { de: unit("Behalten") } },
    Zebra: {},
  });
  const ours = catalog({
    Apple: { localizations: { de: unit("Apfel!"), ru: unit("Яблоко") } },
    Banana: { localizations: { de: unit("Banane (fork)") } },
    Fork: { localizations: { de: unit("Gabel") } },
    Gone: { localizations: { de: unit("Weg") } },
    Kept: { localizations: { de: unit("Behalten"), ru: unit("Оставлено") } },
    Zebra: {},
  });
  const theirs = catalog({
    Added: { localizations: { de: unit("Neu") } },
    Apple: { localizations: { de: unit("Apfel"), ru: unit("Яблочко") } },
    Banana: { localizations: { de: unit("Banane (upstream)") } },
    Zebra: {},
  });
  const { catalog: result, report } = merge(base, ours, theirs);
  const strings = result.get("strings");
  const value = (key, language) =>
    strings.get(key)?.get("localizations")?.get(language)?.get("stringUnit")?.get("value");
  expect(value("Added", "de") === "Neu", "an upstream-only key is added");
  const order = [...strings.keys()].join();
  expect(order === "Added,Apple,Banana,Fork,Kept,Zebra", `theirs' order, ours placed: ${order}`);
  expect(value("Apple", "de") === "Apfel!", "ours' change to one language lands");
  expect(value("Apple", "ru") === "Яблочко", "theirs' change to another language of it lands");
  expect(value("Banana", "de") === "Banane (fork)", "a language both sides changed keeps ours");
  const banana = report.conflicts.find((conflict) => conflict.key === "Banana");
  expect(banana?.languages.join() === "de", "and is reported with its language");
  expect(!strings.has("Gone"), "a key upstream deleted and the fork left alone goes");
  expect(value("Kept", "ru") === "Оставлено", "a key upstream deleted, the fork translated, stays");
  expect(report.conflicts.some((conflict) => conflict.key === "Kept"), "and is reported");
  expect(report.added === 1 && report.removed === 1, `counts: +${report.added} -${report.removed}`);
  expect(report.conflicts.length === 2, `exactly two conflicts, got ${report.conflicts.length}`);

  const renamed = merge(
    catalog({
      "%@ can't use Tinycast": { localizations: { de: unit("%@ kann Tinycast nicht nutzen") } },
      "Keep Tinycast": { localizations: { de: unit("Tinycast behalten") } },
      "Quit Tinycast": { localizations: { de: unit("Tinycast beenden") } },
      "Tinycast Gone": { localizations: { de: unit("Tinycast weg") } },
    }),
    catalog({
      "%@ can't use Tinycast": {
        localizations: { de: unit("%@ kann Redcast nicht nutzen"), en: unit("%@ can't use Redcast") },
      },
      "Keep Tinycast": { localizations: { de: unit("Redcast behalten"), en: unit("Keep Redcast") } },
      "Quit Tinycast": { localizations: { de: unit("Redcast beenden"), en: unit("Quit Redcast") } },
      "Tinycast Gone": { localizations: { de: unit("Redcast weg"), en: unit("Redcast Gone") } },
    }),
    catalog({
      "%@ can’t use Tinycast": { localizations: { de: unit("%@ kann Tinycast nicht nutzen") } },
      "About Tinycast": { localizations: { de: unit("Über Tinycast") } },
      "Keep Tinycast": { localizations: { de: unit("Tinycast behalten") } },
      "Quit Tinycast": { localizations: { de: unit("Tinycast schließen") } },
    }),
  );
  const named = (key, language) =>
    renamed.catalog.get("strings").get(key)?.get("localizations")?.get(language)?.get("stringUnit")
      ?.get("value");
  expect(named("Quit Tinycast", "de") === "Redcast schließen", "an edit to a renamed string lands");
  expect(named("Quit Tinycast", "en") === "Quit Redcast", "renamed, English included");
  expect(named("About Tinycast", "en") === "About Redcast", "an upstream string arrives renamed");
  expect(!renamed.catalog.get("strings").has("Tinycast Gone"), "one the fork only renamed can go");
  expect(renamed.report.conflicts.length === 0, "and renaming alone is never a conflict");
  expect(named("%@ can’t use Tinycast", "en") === "%@ can’t use Redcast",
    "a key upstream rewords in place gets English from its new text");
  expect(!renamed.catalog.get("strings").has("%@ can't use Tinycast"), "and the old key goes");
  const listed = renamed.report.renamed.join(" | ");
  expect(listed === "%@ can’t use Tinycast | About Tinycast | Quit Tinycast",
    `upstream's new and changed strings are listed as renamed: ${listed}`);

  console.log(failures === 0 ? "✓ merge-xcstrings self-test passed" : `✗ ${failures} failed`);
  return failures === 0 ? 0 : 1;
}

const argument = process.argv[2];
if (isMain(import.meta.url) && (argument === "--help" || argument === "-h")) {
  console.log("Usage: node Scripts/fork/merge-xcstrings.mjs [path] | --self-test");
  console.log("Exit codes: 0 clean · 1 conflicts kept as ours (on stderr) · 2 unreadable input");
  process.exit(0);
}
if (isMain(import.meta.url)) {
  process.exit(argument === "--self-test" ? selfTest() : run(argument ?? DEFAULT_PATH));
}
