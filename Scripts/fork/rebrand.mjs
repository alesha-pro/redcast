#!/usr/bin/env node
// Renames the app in the string catalogs, Tinycast to Redcast, idempotently. docs/fork-tooling.md
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { isMain, parse, serialize } from "./xcstrings.mjs";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const CATALOGS = [
  "Tinycast/Resources/Localizable.xcstrings",
  "Tinycast/Resources/InfoPlist.xcstrings",
];
const NAME = "Redcast";

// Text about upstream rather than this app keeps upstream's name. Keys, in either catalog.
export const EXCLUDED = new Map([
  ["Based on Tinycast by Abue Ammar", "About's AGPL credit names upstream and its author"],
  ["Join the Tinycast community", "About's Discord row links upstream's community"],
]);

// Capitalised and whole: `.tinycast`, `tinycast://`, ids, `TinycastAgents` and path parts stay.
const WORD = /(?<![A-Za-z0-9_./])Tinycast(?![A-Za-z0-9_/])/g;

const mentions = (text) => typeof text === "string" && text.search(WORD) >= 0;
const rename = (text) => text.replace(WORD, NAME);
const byCodePoint = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));
const keys = (count) => `${count} ${count === 1 ? "key" : "keys"}`;

const replacing = (map, key, value) =>
  new Map([...map].map(([field, old]) => [field, field === key ? value : old]));

// Xcode keeps an entry's fields and its languages in code-point order.
function withSorted(map, key, value) {
  const entries = [...map];
  const at = entries.findIndex(([other]) => byCodePoint(other, key) > 0);
  entries.splice(at < 0 ? entries.length : at, 0, [key, value]);
  return new Map(entries);
}

// Every `stringUnit` of a localization: its own, its plural and device variations, substitutions.
function* units(node) {
  if (!(node instanceof Map)) return;
  for (const [key, child] of node) {
    if (key === "stringUnit" && child instanceof Map) yield child;
    else yield* units(child);
  }
}

function mentioned(key, entry) {
  if (mentions(key)) return true;
  return [...units(entry.get("localizations"))].some((found) => mentions(found.get("value")));
}

// English gets the renamed key, unless it has text of its own: that is renamed in place.
function rebrandEntry(key, entry) {
  let localizations = entry.get("localizations");
  if (!(localizations instanceof Map)) localizations = new Map();
  for (const found of units(localizations)) {
    const value = found.get("value");
    if (mentions(value)) found.set("value", rename(value));
  }
  if (!localizations.has("en") && mentions(key)) {
    const english = new Map([
      ["state", "translated"],
      ["value", rename(key)],
    ]);
    localizations = withSorted(localizations, "en", new Map([["stringUnit", english]]));
  }
  if (!entry.has("localizations")) return withSorted(entry, "localizations", localizations);
  return replacing(entry, "localizations", localizations);
}

export function rebrand(catalog) {
  const changed = [];
  const excluded = [];
  const strings = catalog.get("strings");
  if (!(strings instanceof Map)) return { catalog, changed, excluded };
  const result = new Map();
  for (const [key, entry] of strings) {
    if (EXCLUDED.has(key)) excluded.push(key);
    if (EXCLUDED.has(key) || !(entry instanceof Map) || !mentioned(key, entry)) {
      result.set(key, entry);
      continue;
    }
    const before = serialize(entry);
    const after = rebrandEntry(key, parse(before));
    if (serialize(after) !== before) changed.push(key);
    result.set(key, after);
  }
  return { catalog: replacing(catalog, "strings", result), changed, excluded };
}

export function rebrandText(text) {
  const { catalog, changed, excluded } = rebrand(parse(text));
  return { text: serialize(catalog) + "\n", changed, excluded };
}

function run(paths, check) {
  const explicit = paths.length > 0;
  const seen = new Set();
  let stale = false;
  for (const path of explicit ? paths : CATALOGS.map((name) => ROOT + name)) {
    const name = path.split("/").pop();
    if (!existsSync(path)) {
      if (!explicit) continue;
      console.error(`✗ ${path} does not exist`);
      return 2;
    }
    const text = readFileSync(path, "utf8");
    let result;
    try {
      result = rebrandText(text);
    } catch (error) {
      console.error(`✗ ${path}: ${error.message}`);
      return 2;
    }
    result.excluded.forEach((key) => seen.add(key));
    if (result.text === text) {
      console.log(`${name}: nothing to rename`);
    } else if (check) {
      stale = true;
      const count = keys(result.changed.length);
      console.error(`✗ ${name}: ${count} still say Tinycast; run Scripts/fork/rebrand.mjs`);
      for (const key of result.changed.slice(0, 20)) console.error(`  ${key}`);
    } else {
      writeFileSync(path, result.text);
      console.log(`${name}: renamed Tinycast in ${keys(result.changed.length)}`);
    }
  }
  for (const key of EXCLUDED.keys()) {
    if (!explicit && !seen.has(key)) console.error(`  ! the exclusion “${key}” is in no catalog`);
  }
  return stale ? 1 : 0;
}

const unit = (value, state = "translated") => ({ stringUnit: { state, value } });
const plural = (forms) => ({
  variations: {
    plural: Object.fromEntries(Object.entries(forms).map(([form, text]) => [form, unit(text)])),
  },
});

const FIXTURE = {
  sourceLanguage: "en",
  strings: {
    "%@: “%@” isn't a shortcut Tinycast can bind": {
      localizations: {
        en: unit("%1$@: “%2$@” isn't a shortcut Tinycast can bind"),
        es: unit("%@: “%@” no es un atajo que Tinycast pueda asignar"),
      },
    },
    "%lld Tinycast windows": {
      localizations: {
        en: plural({ one: "%lld Tinycast window", other: "%lld Tinycast windows" }),
        ru: plural({
          one: "%lld окно Tinycast",
          few: "%lld окна Tinycast",
          many: "%lld окон Tinycast",
          other: "%lld окна Tinycast",
        }),
      },
    },
    "A .tinycast file exported from Tinycast.": {
      localizations: { de: unit("Eine aus Tinycast exportierte .tinycast-Datei.") },
    },
    "Based on Tinycast by Abue Ammar": {
      localizations: { de: unit("Basiert auf Tinycast von Abue Ammar") },
    },
    "Context %#@n@": {
      localizations: {
        en: {
          stringUnit: { state: "translated", value: "Context %#@n@" },
          substitutions: {
            n: {
              argNum: 1,
              formatSpecifier: "lld",
              ...plural({ one: "%arg Tinycast note", other: "%arg Tinycast notes" }),
            },
          },
        },
      },
    },
    NSMicrophoneUsageDescription: {
      extractionState: "manual",
      localizations: {
        en: unit("Tinycast records audio."),
        ru: unit("Tinycast записывает звук."),
      },
    },
    "Open Tinycast": {
      comment: "Opens Tinycast",
      localizations: {
        fr: { variations: { device: { mac: unit("Ouvrir Tinycast"), other: unit("Ouvrir") } } },
        ja: unit("Tinycastを開く", "needs_review"),
        "zh-Hans": unit("打开 Tinycast"),
      },
    },
    "Quit Tinycast": {},
    "TinycastAgents onTinycastChange tinycast:// ~/Tinycast/x": {
      localizations: { de: unit("TinycastAgents onTinycastChange tinycast:// ~/Tinycast/x") },
    },
    "Tinycast’s window, Tinycast-Backup": { localizations: { de: unit("Tinycast-Backup") } },
    "no current meeting": {
      comment: "after “Tinycast: ”",
      localizations: { de: unit("keine aktuelle Besprechung") },
    },
  },
  version: "1.0",
};

function selfTest() {
  let failures = 0;
  const expect = (condition, message) => {
    if (condition) return;
    failures++;
    console.error(`FAIL: ${message}`);
  };
  for (const name of CATALOGS) {
    if (!existsSync(ROOT + name)) continue;
    const committed = readFileSync(ROOT + name, "utf8");
    expect(serialize(parse(committed)) + "\n" === committed, `${name} round-trips`);
  }

  const original = serialize(parse(JSON.stringify(FIXTURE))) + "\n";
  const first = rebrandText(original);
  const strings = parse(first.text).get("strings");
  const loc = (key) => strings.get(key)?.get("localizations");
  const text = (key, ...path) =>
    path.reduce((node, step) => node?.get(step), loc(key))?.get("stringUnit")?.get("value");
  const states = (key) => [...units(loc(key))].map((found) => found.get("state")).join();

  expect(text("Quit Tinycast", "en") === "Quit Redcast", "a bare key gets English");
  expect(states("Quit Tinycast") === "translated", "marked translated");
  expect([...strings.get("Quit Tinycast").keys()].join() === "localizations", "in a new map");
  const shortcut = "%@: “%@” isn't a shortcut Tinycast can bind";
  expect(text(shortcut, "en") === "%1$@: “%2$@” isn't a shortcut Redcast can bind",
    "English of its own is renamed in place, its positions kept");
  expect(text(shortcut, "es") === "%@: “%@” no es un atajo que Redcast pueda asignar",
    "and so is every other language");
  const file = "A .tinycast file exported from Tinycast.";
  expect(text(file, "en") === "A .tinycast file exported from Redcast.", "the extension stays");
  expect(text(file, "de") === "Eine aus Redcast exportierte .tinycast-Datei.", "in German too");
  expect([...loc(file).keys()].join() === "de,en", "English is inserted in code-point order");
  const windows = "%lld Tinycast windows";
  expect(text(windows, "en", "variations", "plural", "one") === "%lld Redcast window",
    "an English plural form is renamed");
  expect(!loc(windows).get("en").has("stringUnit"), "and no plain English is added");
  expect(text(windows, "ru", "variations", "plural", "few") === "%lld окна Redcast",
    "every Russian plural form is renamed");
  expect(text("Context %#@n@", "en", "substitutions", "n", "variations", "plural", "other") ===
    "%arg Redcast notes", "inside a substitution too");
  expect(text("Open Tinycast", "fr", "variations", "device", "mac") === "Ouvrir Redcast",
    "inside a device variation");
  expect(text("Open Tinycast", "ja") === "Redcastを開く", "next to Japanese");
  expect(states("Open Tinycast") === "translated,translated,translated,needs_review,translated",
    "every state is kept");
  expect(strings.get("Open Tinycast").get("comment") === "Opens Tinycast", "comments stay");
  expect([...loc("Open Tinycast").keys()].join() === "en,fr,ja,zh-Hans", "English goes first");
  const mic = "NSMicrophoneUsageDescription";
  expect(text(mic, "en") === "Redcast records audio.", "a usage string is renamed");
  expect(text(mic, "ru") === "Redcast записывает звук.", "in every language");
  expect([...strings.get(mic).keys()].join() === "extractionState,localizations",
    "fields keep their order");
  const odd = "TinycastAgents onTinycastChange tinycast:// ~/Tinycast/x";
  expect(text(odd, "de") === odd && !loc(odd).has("en"), "ids, schemes and paths stay");
  const word = "Tinycast’s window, Tinycast-Backup";
  expect(text(word, "en") === "Redcast’s window, Redcast-Backup", "a possessive is renamed");
  expect(text(word, "de") === "Redcast-Backup", "and so is a compound");
  const credit = "Based on Tinycast by Abue Ammar";
  expect(serialize(strings.get(credit)) === serialize(parse(original).get("strings").get(credit)),
    "the credit stays byte for byte");
  expect(first.excluded.join() === credit, "and is reported as excluded");
  expect(!loc("no current meeting").has("en"), "a mention in a comment changes nothing");
  expect(first.changed.length === 8 && !first.changed.includes("no current meeting"),
    `eight keys change, got ${first.changed.length}`);
  const second = rebrandText(first.text);
  expect(second.text === first.text && second.changed.length === 0, "a second run changes nothing");
  expect(first.text !== original, "so --check fails before a run and passes after it");

  console.log(failures === 0 ? "✓ rebrand self-test passed" : `✗ ${failures} failed`);
  return failures === 0 ? 0 : 1;
}

if (isMain(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.includes("--help") || args.includes("-h")) {
    console.log("Usage: node Scripts/fork/rebrand.mjs [--check] [catalog…] | --self-test");
    console.log("Exit codes: 0 rebranded · 1 --check found Tinycast to rename · 2 unreadable");
    console.log("Kept as Tinycast:");
    for (const [key, reason] of EXCLUDED) console.log(`  “${key}”: ${reason}`);
    process.exit(0);
  }
  if (args.includes("--self-test")) process.exit(selfTest());
  process.exit(run(args.filter((arg) => arg !== "--check"), args.includes("--check")));
}
