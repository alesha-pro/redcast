// A string catalog's JSON, read and written back byte for byte as Xcode writes it.
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const LITERAL = /^(?:true|false|null|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)/;

// Maps keep key order; a plain object would hoist integer-like keys to the front.
export function parse(text) {
  let at = 0;
  const skip = () => {
    while (at < text.length && " \t\n\r".includes(text[at])) at++;
  };
  const expect = (char) => {
    skip();
    if (text[at] !== char) throw new SyntaxError(`expected ${char} at ${at}`);
    at++;
  };
  const string = () => {
    skip();
    if (text[at] !== '"') throw new SyntaxError(`expected a string at ${at}`);
    const start = at++;
    while (at < text.length && text[at] !== '"') at += text[at] === "\\" ? 2 : 1;
    return JSON.parse(text.slice(start, ++at));
  };
  const collection = (close, read) => {
    at++;
    skip();
    if (text[at] === close) return at++;
    for (;;) {
      read();
      skip();
      if (text[at] === close) return at++;
      expect(",");
    }
  };
  const value = () => {
    skip();
    if (text[at] === "{") {
      const map = new Map();
      collection("}", () => {
        const key = string();
        expect(":");
        map.set(key, value());
      });
      return map;
    }
    if (text[at] === "[") {
      const list = [];
      collection("]", () => list.push(value()));
      return list;
    }
    if (text[at] === '"') return string();
    const literal = LITERAL.exec(text.slice(at, at + 32));
    if (!literal) throw new SyntaxError(`unexpected input at ${at}`);
    at += literal[0].length;
    return JSON.parse(literal[0]);
  };
  const result = value();
  skip();
  if (at !== text.length) throw new SyntaxError(`trailing input at ${at}`);
  return result;
}

// Xcode's own layout: two-space indent, " : ", and an empty object written across a blank line.
export function serialize(value, indent = "") {
  const inner = indent + "  ";
  if (value instanceof Map) {
    if (value.size === 0) return `{\n\n${indent}}`;
    const members = [...value].map(
      ([key, item]) => `${inner}${JSON.stringify(key)} : ${serialize(item, inner)}`,
    );
    return `{\n${members.join(",\n")}\n${indent}}`;
  }
  if (Array.isArray(value)) {
    if (value.length === 0) return `[\n\n${indent}]`;
    return `[\n${value.map((item) => inner + serialize(item, inner)).join(",\n")}\n${indent}]`;
  }
  return JSON.stringify(value);
}

// The fork's scripts import one another; only the one node was started with runs.
export function isMain(url) {
  try {
    return realpathSync(process.argv[1]) === fileURLToPath(url);
  } catch {
    return false;
  }
}
