#!/usr/bin/env node
// Renames the app in the string catalogs and docs, Tinycast to Redcast, idempotently. docs/fork-tooling.md
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { isMain, parse, serialize } from "./xcstrings.mjs";
import {
  ALLOWED_PROSE, ALLOWED_SWIFT, docMentions, rebrandDoc, skeleton, swiftMentions, tracked,
} from "./rebrand-text.mjs";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const CATALOGS = [
  "Tinycast/Resources/Localizable.xcstrings",
  "Tinycast/Resources/InfoPlist.xcstrings",
];
const INFO_PLIST = "Tinycast/Info.plist";
const NAME = "Redcast";

// Text about upstream rather than this app keeps upstream's name. Keys, in either catalog.
export const EXCLUDED = new Map([
  ["A modified version of Tinycast, © 2026 Abue Ammar.", "About's AGPL notice names upstream and its author"],
  ["Join the Tinycast community", "About's Discord row links upstream's community"],
  ["Support Tinycast", "the support checkout is upstream's and funds its author"],
]);

// Capitalised and whole, a genitive `s` allowed: `.tinycast`, `tinycast://`, ids,
// `TinycastAgents` and path parts stay.
const word = (name) => new RegExp(`(?<![A-Za-z0-9_./])${name}(?=s?(?![A-Za-z0-9_/]))`, "g");
const WORD = word("Tinycast");
const RENAMED = word(NAME);
// The backup file's extension, `.redcast` since Redcast writes it; `com.tinycast.backup` stays.
const EXTENSION = /(?<![A-Za-z0-9_/])\.tinycast(?![A-Za-z0-9_])/g;
const MENTION = new RegExp(`${WORD.source}|${EXTENSION.source}`, "g");

const says = (text, pattern) => typeof text === "string" && text.search(pattern) >= 0;
const mentions = (text) => says(text, MENTION);
const rename = (text) => text.replace(WORD, NAME).replace(EXTENSION, ".redcast");
const quoted = (key) => JSON.stringify(key);
const byCodePoint = (a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b));
const keys = (count) => `${count} ${count === 1 ? "key" : "keys"}`;
const say = (count) => (count === 1 ? "says" : "say");

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

function mentioned(key, entry, pattern = WORD) {
  if (says(key, pattern)) return true;
  return [...units(entry.get("localizations"))].some((found) => says(found.get("value"), pattern));
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

// An entry renamed before it joined EXCLUDED gets upstream's name back, and loses the English the
// rename gave it, which only repeated the key.
function restoreEntry(key, entry) {
  const localizations = entry.get("localizations");
  for (const found of units(localizations)) {
    const value = found.get("value");
    if (says(value, RENAMED)) found.set("value", value.replace(RENAMED, "Tinycast"));
  }
  const english = localizations.get("en");
  const unit = english instanceof Map && english.size === 1 ? english.get("stringUnit") : undefined;
  if (unit instanceof Map && unit.get("value") === key) localizations.delete("en");
  if (localizations.size > 0) return entry;
  return new Map([...entry].filter(([field]) => field !== "localizations"));
}

export function rebrand(catalog) {
  const changed = [];
  const restored = [];
  const excluded = [];
  const strings = catalog.get("strings");
  if (!(strings instanceof Map)) return { catalog, changed, restored, excluded };
  const result = new Map();
  for (const [key, entry] of strings) {
    const exclude = EXCLUDED.has(key);
    if (exclude) excluded.push(key);
    if (!(entry instanceof Map) || !mentioned(key, entry, exclude ? RENAMED : MENTION)) {
      result.set(key, entry);
      continue;
    }
    const before = serialize(entry);
    const after = exclude ? restoreEntry(key, parse(before)) : rebrandEntry(key, parse(before));
    if (serialize(after) !== before) (exclude ? restored : changed).push(key);
    result.set(key, after);
  }
  return { catalog: replacing(catalog, "strings", result), changed, restored, excluded };
}

export function rebrandText(text) {
  const { catalog, ...found } = rebrand(parse(text));
  return { text: serialize(catalog) + "\n", ...found };
}

const XML_ENTITIES = { amp: "&", apos: "'", gt: ">", lt: "<", quot: '"' };
const PLIST_STRING = /<key>(\w+)<\/key>\s*<string>([^<]*)<\/string>/g;

// Info.plist's text shows as it is in a language the catalog gives no value: these name Tinycast
// where InfoPlist.xcstrings has no English for them, prompts, type names and any other value.
export function uncovered(plist, catalog) {
  const strings = catalog.get("strings") ?? new Map();
  const missing = [];
  for (const [, field, raw] of plist.matchAll(PLIST_STRING)) {
    const text = raw.replace(/&(amp|apos|gt|lt|quot);/g, (_, name) => XML_ENTITIES[name]);
    // Xcode keys a usage string by its Info.plist key, and anything else by its text.
    const key = field.endsWith("UsageDescription") ? field : text;
    if (!says(text, WORD) || EXCLUDED.has(key)) continue;
    const english = strings.get(key)?.get?.("localizations")?.get("en")?.get("stringUnit");
    const value = english instanceof Map ? english.get("value") : undefined;
    if (typeof value !== "string" || says(value, WORD)) missing.push(key);
  }
  return missing;
}

// Each key on a line of its own, quoted, so a sync can list exactly what it renamed.
function list(heading, found, print, limit = Infinity) {
  if (found.length === 0) return;
  print(heading);
  for (const key of found.slice(0, limit)) print(`  ${quoted(key)}`);
  if (found.length > limit) print(`  … and ${found.length - limit} more`);
}

function run(paths, check) {
  const explicit = paths.length > 0;
  const seen = new Set();
  let stale = false;
  let infoCatalog;
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
    if (path === ROOT + CATALOGS[1]) infoCatalog = parse(result.text);
    const { changed, restored } = result;
    if (result.text === text) {
      console.log(`${name}: nothing to rename`);
    } else if (check) {
      stale = true;
      const print = (line) => console.error(line);
      const rerun = "run Scripts/fork/rebrand.mjs";
      list(`✗ ${name}: ${keys(changed.length)} still ${say(changed.length)} Tinycast; ${rerun}`,
        changed, print, 20);
      const back = `${keys(restored.length)} in EXCLUDED ${say(restored.length)} Redcast`;
      list(`✗ ${name}: ${back}; ${rerun}`, restored, print, 20);
    } else {
      writeFileSync(path, result.text);
      const print = (line) => console.log(line);
      list(`${name}: renamed Tinycast in ${keys(changed.length)}`, changed, print);
      list(`${name}: restored Tinycast in ${keys(restored.length)} in EXCLUDED`, restored, print);
    }
  }
  if (explicit) return stale ? 1 : 0;
  for (const key of EXCLUDED.keys()) {
    if (seen.has(key)) continue;
    console.error(`! the exclusion ${quoted(key)} is in no catalog: upstream reworded or removed it;`
      + " point the exclusion at its new key, or drop it");
  }
  if (infoCatalog && existsSync(ROOT + INFO_PLIST)) {
    for (const key of uncovered(readFileSync(ROOT + INFO_PLIST, "utf8"), infoCatalog)) {
      stale ||= check;
      console.error(`${check ? "✗" : "!"} Info.plist's ${quoted(key)} says Tinycast, and`
        + " InfoPlist.xcstrings has no English for it: build in Xcode to extract it, then rerun");
    }
  }
  if (!runDocs(check)) stale = true;
  if (check && !checkSwift()) stale = true;
  return stale ? 1 : 0;
}

// Markdown prose says Redcast; ALLOWED_PROSE keeps the legal attribution. Code spans, links' targets
// and fenced code keep their paths and ids.
function runDocs(check) {
  const found = [];
  for (const path of tracked(ROOT, "*.md")) {
    if (!existsSync(ROOT + path)) continue;
    const text = readFileSync(ROOT + path, "utf8");
    if (check) {
      for (const hit of docMentions(path, text)) found.push(`${path}:${hit.line}: ${hit.text}`);
      continue;
    }
    const result = rebrandDoc(path, text);
    if (result.text === text) continue;
    writeFileSync(ROOT + path, result.text);
    console.log(`${path}: renamed Tinycast on ${result.renamed.length} lines`);
  }
  if (found.length === 0) return true;
  console.error(`✗ ${found.length} Markdown lines still say Tinycast; run Scripts/fork/rebrand.mjs,`
    + " say upstream where a line means it, or add the line to ALLOWED_PROSE");
  for (const line of found.slice(0, 20)) console.error(`  ${line.slice(0, 160)}`);
  if (found.length > 20) console.error(`  … and ${found.length - 20} more`);
  return false;
}

// Swift literals that are no catalog key show as written: they say Redcast, or end `.forkBranded`.
function checkSwift() {
  const catalog = parse(readFileSync(ROOT + CATALOGS[0], "utf8")).get("strings") ?? new Map();
  const keys = new Set([...catalog.keys()].map(skeleton));
  const found = [];
  for (const path of tracked(ROOT, "Tinycast/*.swift")) {
    if (!existsSync(ROOT + path)) continue;
    for (const hit of swiftMentions(path, readFileSync(ROOT + path, "utf8"), keys)) {
      found.push(`${path}:${hit.line}: "${hit.text}"`);
    }
  }
  if (found.length === 0) return true;
  console.error(`✗ ${found.length} Swift literals outside the catalogs say Tinycast: say Redcast,`
    + " append .forkBranded, or add them to ALLOWED_SWIFT with a reason");
  for (const line of found.slice(0, 20)) console.error(`  ${line}`);
  if (found.length > 20) console.error(`  … and ${found.length - 20} more`);
  return false;
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
    "A modified version of Tinycast, © 2026 Abue Ammar.": {
      localizations: { de: unit("Eine geänderte Version von Tinycast, © 2026 Abue Ammar.") },
    },
    "com.tinycast.backup files end .tinycast, not x.tinycast2": {},
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
    "Support Tinycast": {
      localizations: { de: unit("Redcast unterstützen"), en: unit("Support Redcast") },
    },
    "Tinycast window": { localizations: { de: unit("Tinycasts Fenster") } },
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
  expect(text(file, "en") === "A .redcast file exported from Redcast.", "the extension is renamed");
  expect(text(file, "de") === "Eine aus Redcast exportierte .redcast-Datei.", "in German too");
  const ext = "com.tinycast.backup files end .tinycast, not x.tinycast2";
  expect(text(ext, "en") === "com.tinycast.backup files end .redcast, not x.tinycast2",
    "only a whole extension, never an id's or a longer one");
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
  expect(text("Tinycast window", "en") === "Redcast window", "a plain key is renamed");
  expect(text("Tinycast window", "de") === "Redcasts Fenster", "and so is a German genitive");
  const odd = "TinycastAgents onTinycastChange tinycast:// ~/Tinycast/x";
  expect(text(odd, "de") === odd && !loc(odd).has("en"), "ids, schemes and paths stay");
  const word = "Tinycast’s window, Tinycast-Backup";
  expect(text(word, "en") === "Redcast’s window, Redcast-Backup", "a possessive is renamed");
  expect(text(word, "de") === "Redcast-Backup", "and so is a compound");
  const credit = "A modified version of Tinycast, © 2026 Abue Ammar.";
  expect(serialize(strings.get(credit)) === serialize(parse(original).get("strings").get(credit)),
    "the credit stays byte for byte");
  expect(first.excluded.join() === `${credit},Support Tinycast`, "and is reported as excluded");
  expect(text("Support Tinycast", "de") === "Tinycast unterstützen",
    "a key renamed before it was excluded gets Tinycast back");
  expect(!loc("Support Tinycast").has("en"), "and loses the English that repeated its key");
  expect(first.restored.join() === "Support Tinycast", "and is reported as restored");
  expect(!loc("no current meeting").has("en"), "a mention in a comment changes nothing");
  expect(first.changed.length === 10 && !first.changed.includes("no current meeting"),
    `ten keys change, got ${first.changed.length}`);
  const second = rebrandText(first.text);
  expect(second.text === first.text && second.changed.length + second.restored.length === 0,
    "a second run changes nothing");
  expect(first.text !== original, "so --check fails before a run and passes after it");

  const plist = [
    "<key>NSCameraUsageDescription</key>\n\t<string>Tinycast films &amp; snaps.</string>",
    "<key>NSFooUsageDescription</key><string>Tinycast foos.</string>",
    "<key>NSBarUsageDescription</key><string>Bars.</string>",
    "<key>UTTypeDescription</key><string>Tinycast Backup</string>",
    "<key>NSHumanReadableCopyright</key><string>Tinycast</string>",
  ].join("\n");
  const prompts = rebrand(parse(JSON.stringify({
    strings: {
      NSCameraUsageDescription: { localizations: { en: unit("Tinycast films & snaps.") } },
      NSFooUsageDescription: { localizations: { de: unit("Tinycast foot.") } },
      "Tinycast Backup": { localizations: { de: unit("Tinycast-Sicherung") } },
    },
  }))).catalog;
  expect(uncovered(plist, prompts).join() === "NSFooUsageDescription,Tinycast",
    "a prompt or any other value naming Tinycast with no English in the catalog is found");
  const info = ROOT + INFO_PLIST;
  if (existsSync(info) && existsSync(ROOT + CATALOGS[1])) {
    const committed = parse(readFileSync(ROOT + CATALOGS[1], "utf8"));
    const missing = uncovered(readFileSync(info, "utf8"), committed);
    expect(missing.length === 0, `Info.plist's prompts all say Redcast: ${missing.join(", ")}`);
  }

  console.log(failures === 0 ? "✓ rebrand self-test passed" : `✗ ${failures} failed`);
  return failures === 0 ? 0 : 1;
}

if (isMain(import.meta.url)) {
  const args = process.argv.slice(2);
  if (args.includes("--help") || args.includes("-h")) {
    console.log("Usage: node Scripts/fork/rebrand.mjs [--check] [catalog…] | --self-test");
    console.log("Exit codes: 0 rebranded · 1 --check found a key to rename or restore, or an"
      + " Info.plist prompt with no English · 2 unreadable");
    console.log("       node Scripts/fork/rebrand.mjs --doc PATH < upstream.md  # one doc, stdin to stdout");
    console.log("Kept as Tinycast:");
    for (const [key, reason] of EXCLUDED) console.log(`  “${key}”: ${reason}`);
    for (const [path, lines] of ALLOWED_PROSE) {
      for (const [phrase, reason] of lines) console.log(`  ${path} “${phrase}…”: ${reason}`);
    }
    for (const [path, piece, reason] of ALLOWED_SWIFT) console.log(`  ${path} “${piece}”: ${reason}`);
    process.exit(0);
  }
  const doc = args.indexOf("--doc");
  if (doc >= 0) {
    process.stdout.write(rebrandDoc(args[doc + 1] ?? "", readFileSync(0, "utf8")).text);
    process.exit(0);
  }
  if (args.includes("--self-test")) process.exit(selfTest());
  process.exit(run(args.filter((arg) => arg !== "--check"), args.includes("--check")));
}
