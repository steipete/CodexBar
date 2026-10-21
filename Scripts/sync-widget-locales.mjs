#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const keys = JSON.parse(fs.readFileSync(path.join(root, "Scripts/widget-localization-keys.json"), "utf8"));
const source = path.join(root, "Sources/CodexBar/Resources");
const target = path.join(root, "Sources/CodexBarWidget/Resources");
const check = process.argv.includes("--check");
let failed = false;
let count = 0;
for (const locale of fs.readdirSync(source).filter((name) => name.endsWith(".lproj"))) {
  const sourceFile = path.join(source, locale, "Localizable.strings");
  const catalog = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", sourceFile], { encoding: "utf8" }));
  const lines = keys.map((key) => {
    if (!Object.hasOwn(catalog, key)) throw new Error(`${locale}: missing widget key ${key}`);
    return `${JSON.stringify(key)} = ${JSON.stringify(catalog[key])};`;
  });
  const content = `/* Generated from the app catalogs by Scripts/sync-widget-locales.mjs. */\n${lines.join("\n")}\n`;
  const destination = path.join(target, locale, "Localizable.strings");
  if (check) {
    if (!fs.existsSync(destination) || fs.readFileSync(destination, "utf8") !== content) {
      console.error(`${locale}: widget catalog is out of date`);
      failed = true;
    }
  } else {
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.writeFileSync(destination, content);
  }
  count++;
}
if (failed) process.exit(1);
console.log(`Widget catalogs ${check ? "OK" : "generated"}: ${count} locales, ${keys.length} keys.`);
