#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const resources = path.join(repoRoot, "Sources/CodexBar/Resources");
const english = readCatalog("en");
const englishKeys = Object.keys(english).sort();
const newLocales = ["ar", "fa", "th"];
const languageKeys = ["language_arabic", "language_persian", "language_thai"];

for (const locale of newLocales) {
  const catalog = readCatalog(locale);
  assertEqual(Object.keys(catalog).sort(), englishKeys, `${locale} catalog keys`);
  for (const key of englishKeys) {
    assert(catalog[key].trim(), `${locale}.${key} is blank`);
    assertEqual(tokens(catalog[key]), tokens(english[key]), `${locale}.${key} tokens`);
  }
}

for (const directory of fs.readdirSync(resources).filter((name) => name.endsWith(".lproj"))) {
  const catalog = readCatalog(directory.replace(/\.lproj$/, ""));
  for (const key of languageKeys) assert(catalog[key]?.trim(), `${directory} missing ${key}`);
}

console.log(`app locales OK: ${newLocales.length} complete catalogs, ${englishKeys.length} keys`);

function readCatalog(locale) {
  const file = path.join(resources, `${locale}.lproj/Localizable.strings`);
  const output = execFileSync("plutil", ["-convert", "json", "-o", "-", file], { encoding: "utf8" });
  return JSON.parse(output);
}

function tokens(value) {
  const printf = value.match(/%(?:\d+\$)?(?:\.\d+)?(?:@|d|f|%)/g) ?? [];
  const swift = value.match(/\\\([^)]*\)/g) ?? [];
  return [...printf, ...swift].sort();
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertEqual(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}
