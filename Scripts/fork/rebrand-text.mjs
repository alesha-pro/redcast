// Upstream's name in the fork's Markdown prose and Swift string literals: renamed, or found for
// `rebrand.mjs --check`. docs/fork-tooling.md
import { execFileSync } from "node:child_process";

export const NAME = "Redcast";
// Capitalised and whole, a genitive `s` allowed, as rebrand.mjs renames catalog values.
export const WORD = /(?<![A-Za-z0-9_./])Tinycast(?=s?(?![A-Za-z0-9_/]))/g;

// The prose lines that keep upstream's name, by file: legal attribution only.
export const ALLOWED_PROSE = new Map([
  ["README.md", [
    ["Redcast is a modified version of [Tinycast]", "the one attribution AGPL-3.0 §4 and §5(a) ask for"],
  ]],
]);

// Swift literals that keep upstream's name, by file and a piece of the literal.
export const ALLOWED_SWIFT = [
  ["Tinycast/Features/AI/Model/ForkBrand.swift", "Tinycast", "the word ForkBrand renames"],
  ["Tinycast/Features/Support/UI/SupportCoordinator.swift", "Tinycast",
    "the Support window's checkout is upstream's and funds its author"],
  ["Tinycast/Features/Dictation/Service/DictationWorker.swift", "Tinycast",
    "the Debug channel's helper name, set in project.yml, and a fallback no fork build reaches"],
  ["Tinycast/Features/FullBackup/Model/FullBackupAutoExportPolicy.swift", "Tinycast-Auto-",
    "older builds' automatic exports, recognised only so they age out"],
  ["Tinycast/Platform/AppDisplayName.swift", "Tinycast",
    "the fallback when the bundle names nothing, which a fork build never is"],
  ["Tinycast/Features/Extensions/Service/ExtensionHostBridge.swift", "not supported in Tinycast extensions",
    "one wording with the extension runtime's own errors, upstream's sources; a harness asserts it"],
];

// Code that logs or traps, whose text a user never reads.
const DEVELOPER = /\b(NSLog|os_log|print|fatalError|assertionFailure|preconditionFailure|debugPrint)\s*\($/;

const blank = (text) => text.replace(/[^\n]/g, " ");

// The line with everything that is not prose blanked: code spans, link targets, URLs, HTML.
function proseOf(line) {
  return line
    .replace(/(`+)[\s\S]*?\1/g, blank)
    .replace(/\]\([^)]*\)/g, blank)
    .replace(/<[^>\n]*>/g, blank)
    .replace(/\bhttps?:\/\/\S+/g, blank)
    .replace(/^\s*\[[^\]]+\]:\s*\S+/g, blank);
}

// Each prose line with its mentions, outside fenced code and HTML comments.
function* proseLines(text) {
  let fence = null;
  let comment = false;
  const lines = text.split("\n");
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    const opener = line.match(/^\s*(`{3,}|~{3,})/);
    if (fence) {
      if (opener && opener[1][0] === fence[0] && opener[1].length >= fence.length) fence = null;
      continue;
    }
    if (opener) {
      fence = opener[1];
      continue;
    }
    let prose = line;
    if (comment) {
      const end = prose.indexOf("-->");
      if (end < 0) continue;
      prose = blank(prose.slice(0, end + 3)) + prose.slice(end + 3);
      comment = false;
    }
    prose = prose.replace(/<!--[\s\S]*?-->/g, blank);
    const open = prose.indexOf("<!--");
    if (open >= 0) {
      prose = prose.slice(0, open) + blank(prose.slice(open));
      comment = true;
    }
    yield { index, line, prose: proseOf(prose) };
  }
}

// A link to upstream's repository names upstream: never renamed, and `--check` still lists it.
const UPSTREAM_LINK = /\[[^\]]*\]\(https:\/\/github\.com\/abue-ammar\/tinycast[^)]*\)/g;
const upstreamLinks = (line) => [...line.matchAll(UPSTREAM_LINK)].map((m) => [m.index, m.index + m[0].length]);

const allowedIn = (path, line) =>
  (ALLOWED_PROSE.get(path) ?? []).some(([phrase]) => line.includes(phrase));

// A relative link's anchor follows a heading the rename changed.
const anchors = (line) =>
  line.replace(/\]\(([^)\s]*)#([^)\s]*)\)/g, (whole, target, fragment) =>
    target.includes("://") ? whole : `](${target}#${fragment.replace(/tinycast/g, "redcast")})`);

export function rebrandDoc(path, text) {
  const lines = text.split("\n");
  const renamed = [];
  for (const { index, line, prose } of proseLines(text)) {
    let next = anchors(line);
    if (!allowedIn(path, line)) {
      const links = upstreamLinks(line);
      const hits = [...prose.matchAll(WORD)].map((hit) => hit.index)
        .filter((at) => !links.some(([start, end]) => at >= start && at < end)).reverse();
      for (const at of hits) next = next.slice(0, at) + NAME + next.slice(at + "Tinycast".length);
    }
    if (next !== line) {
      lines[index] = next;
      renamed.push(index + 1);
    }
  }
  return { text: lines.join("\n"), renamed };
}

export function docMentions(path, text) {
  const found = [];
  for (const { index, line, prose } of proseLines(text)) {
    if (allowedIn(path, line)) continue;
    if ([...prose.matchAll(WORD)].length > 0) found.push({ line: index + 1, text: line.trim() });
  }
  return found;
}

// Swift's escapes, a multi-line literal's line continuations and its closing indentation.
function unescape(raw, multiline) {
  let text = raw;
  if (multiline) {
    const lines = text.split("\n").slice(1);
    const indent = lines.at(-1).match(/^\s*/)[0];
    text = lines.slice(0, -1).map((line) => line.startsWith(indent) ? line.slice(indent.length) : line)
      .join("\n").replace(/\\[ \t]*\n/g, "");
  }
  return text.replace(/\\(u\{([0-9a-fA-F]+)\}|.)/g, (_, escape, hex) => {
    if (hex) return String.fromCodePoint(parseInt(hex, 16));
    return { n: "\n", t: "\t", r: "\r", 0: "\0" }[escape] ?? escape;
  });
}

// Every string literal in a Swift file, its interpolations as `\0`, with what precedes and follows.
export function swiftLiterals(source) {
  const found = [];
  let at = 0;
  let line = 1;
  const advance = (count) => {
    for (let index = 0; index < count; index++) if (source[at + index] === "\n") line++;
    at += count;
  };
  // Code until the `)` that closes an interpolation, or the end of the file.
  const code = (top) => {
    let depth = 0;
    while (at < source.length) {
      const char = source[at];
      if (source.startsWith("//", at)) {
        while (at < source.length && source[at] !== "\n") at++;
      } else if (source.startsWith("/*", at)) {
        let nesting = 0;
        do {
          if (source.startsWith("/*", at)) { nesting++; advance(2); }
          else if (source.startsWith("*/", at)) { nesting--; advance(2); }
          else advance(1);
        } while (nesting > 0 && at < source.length);
      } else if (char === '"' || (char === "#" && /^#+"/.test(source.slice(at, at + 8)))) {
        literal();
      } else if (char === "(") {
        depth++;
        advance(1);
      } else if (char === ")") {
        advance(1);
        if (--depth < 0 && !top) return;
      } else {
        advance(1);
      }
    }
  };
  const literal = () => {
    const start = line;
    const before = source.slice(source.lastIndexOf("\n", at - 1) + 1, at);
    const hashes = source.slice(at).match(/^#*/)[0];
    advance(hashes.length);
    const multiline = source.startsWith('"""', at);
    const quote = multiline ? '"""' : '"';
    const close = quote + hashes;
    advance(quote.length);
    let raw = "";
    while (at < source.length && !source.startsWith(close, at)) {
      if (source.startsWith("\\" + hashes + "(", at)) {
        advance(hashes.length + 2);
        code(false);
        raw += "\0";
      } else if (source[at] === "\\" && hashes === "") {
        raw += source.slice(at, at + 2);
        advance(2);
      } else {
        raw += source[at];
        advance(1);
      }
    }
    advance(close.length);
    const text = hashes ? raw : unescape(raw, multiline);
    found.push({ line: start, text, before, after: source.slice(at, at + 40) });
  };
  code(true);
  return found;
}

// A catalog key or a literal, its format specifiers and interpolations alike.
const SPECIFIER = /%(\d+\$)?(#@\w+@|ll[du]|l?[dDuUxXoOfFeEgGcCsSpaA@])/g;
export const skeleton = (key) => key.replace(SPECIFIER, "\0");

export function swiftMentions(path, source, keys) {
  const found = [];
  for (const { line, text, before, after } of swiftLiterals(source)) {
    if ([...text.matchAll(WORD)].length === 0) continue;
    if (keys.has(text)) continue;
    if (/^\s*\.forkBranded\b/.test(after)) continue;
    if (DEVELOPER.test(before.trimEnd())) continue;
    if (ALLOWED_SWIFT.some(([file, piece]) => file === path && text.includes(piece))) continue;
    found.push({ line, text: text.split("\n")[0].slice(0, 100) });
  }
  return found;
}

export function tracked(root, ...patterns) {
  const output = execFileSync("git", ["-C", root, "ls-files", "-z", "--", ...patterns], { encoding: "utf8" });
  return output.split("\0").filter(Boolean);
}
