#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const resources = path.join(repoRoot, "Sources/CodexBar/Resources");
const english = readCatalog("en");
const englishKeys = Object.keys(english).sort();
const strictLocales = ["ar", "fa", "th"];
const languageKeys = ["language_arabic", "language_persian", "language_thai"];
const isTest = process.argv.includes("--test");

function readCatalog(locale) {
  const file = path.join(resources, `${locale}.lproj/Localizable.strings`);
  if (!fs.existsSync(file)) return null;
  const output = execFileSync("plutil", ["-convert", "json", "-o", "-", file], { encoding: "utf8" });
  return JSON.parse(output);
}

function tokenSignature(value) {
  // Exclude explicit `%%`, which does not consume an argument.
  const withoutEscapedPercents = value.replace(/%%/g, "");
  const printfRaw = withoutEscapedPercents.match(/%(?:\d+\$)?(?:\.\d+)?(?:@|d|f)/g) ?? [];

  const printf = {};
  let implicitIndex = 1;
  for (const token of printfRaw) {
    const match = token.match(/%(\d+)\$.*?([@df])/);
    if (match) {
      printf[Number.parseInt(match[1], 10)] = match[2];
    } else {
      printf[implicitIndex] = token.at(-1);
      implicitIndex += 1;
    }
  }

  return { printf, swift: swiftInterpolationTokens(value).sort() };
}

function formatKeyList(keys, limit = 12) {
  const shown = keys.slice(0, limit).join(", ");
  const remaining = keys.length - limit;
  return remaining > 0 ? `${shown}, ... +${remaining} more` : shown;
}

function blankKeys(catalog, referenceKeys) {
  return referenceKeys.filter((key) => Object.hasOwn(catalog, key) && !catalog[key]?.trim());
}

function swiftInterpolationTokens(value) {
  const tokens = [];
  for (let index = 0; index < value.length - 1; index += 1) {
    if (value[index] !== "\\" || value[index + 1] !== "(") continue;

    const start = index;
    let depth = 1;
    index += 2;
    while (index < value.length && depth > 0) {
      if (value[index] === "(") depth += 1;
      if (value[index] === ")") depth -= 1;
      index += 1;
    }
    tokens.push(value.slice(start, index));
    index -= 1;
  }
  return tokens;
}

if (isTest) {
  assertEqual(tokenSignature("%1$@ · %2$d"), tokenSignature("%2$d · %1$@"), "positional reorder");
  assertNotEqual(tokenSignature("%1$@ · %2$d"), tokenSignature("%1$d · %2$@"), "positional type swap");
  assertEqual(tokenSignature("%.0f%% used"), tokenSignature("%.0f%% verbraucht"), "escaped percent");
  assertNotEqual(tokenSignature("\\(name): \\(usage)"), tokenSignature("\\(name): \\(value)"), "Swift tokens");
  assertEqual(
    tokenSignature("\\(self.store.metadata(for: self.provider).displayName) failed"),
    tokenSignature("Fehler: \\(self.store.metadata(for: self.provider).displayName)"),
    "nested Swift interpolation");
  assertNotEqual(
    tokenSignature("\\(self.store.metadata(for: self.provider).displayName) failed"),
    tokenSignature("\\(self.store.metadata(for: self.provider) failed"),
    "truncated Swift interpolation");
  assertEqual(formatKeyList(["alpha", "beta"]), "alpha, beta", "short key list");
  assertEqual(
    formatKeyList(["alpha", "beta", "gamma", "delta"], 2),
    "alpha, beta, ... +2 more",
    "truncated key list");
  assertEqual(
    blankKeys({ alpha: "", beta: "  ", gamma: "ok" }, ["alpha", "beta", "gamma", "delta"]),
    ["alpha", "beta"],
    "blank keys");
  console.log("app locale checker tests OK");
  process.exit(0);
}

let hasErrors = false;
let checkedCount = 0;

for (const strictLocale of strictLocales) {
  const dirPath = path.join(resources, `${strictLocale}.lproj`);
  if (!fs.existsSync(dirPath)) {
    console.error(`\x1b[31mError: Required strict locale catalog is completely missing: ${strictLocale}.lproj\x1b[0m`);
    hasErrors = true;
  }
}

for (const directory of fs.readdirSync(resources).filter((name) => name.endsWith(".lproj"))) {
  const locale = directory.replace(/\.lproj$/, "");
  if (locale === "en" || locale === "Base") continue;
  
  const catalog = readCatalog(locale);
  if (!catalog) continue;

  checkedCount++;
  const catalogKeys = Object.keys(catalog);
  const emptyKeys = blankKeys(catalog, englishKeys);

  // 1. Missing keys
  const missingKeys = englishKeys.filter((key) => !catalogKeys.includes(key));
  if (missingKeys.length > 0) {
    const missingKeyList = formatKeyList(missingKeys);
    if (strictLocales.includes(locale)) {
      console.error(
        `\x1b[31m[${locale}] Error: Missing ${missingKeys.length} keys in strict locale: ${missingKeyList}.\x1b[0m`);
      hasErrors = true;
    } else {
      console.warn(`\x1b[33m[${locale}] Warning: Missing ${missingKeys.length} keys: ${missingKeyList}.\x1b[0m`);
    }
  }

  const extraKeys = catalogKeys.filter((key) => !englishKeys.includes(key));
  if (strictLocales.includes(locale) && extraKeys.length > 0) {
    console.error(`\x1b[31m[${locale}] Error: Found ${extraKeys.length} extra keys in strict locale.\x1b[0m`);
    hasErrors = true;
  }

  // Ensure critical language keys are present in ALL locales
  for (const key of languageKeys) {
    if (!catalog[key] || !catalog[key].trim()) {
      console.error(`\x1b[31m[${locale}] Error: Missing critical language key "${key}".\x1b[0m`);
      hasErrors = true;
    }
  }

  if (emptyKeys.length > 0) {
    console.error(
      `\x1b[31m[${locale}] Error: Blank values for ${emptyKeys.length} keys: ${formatKeyList(emptyKeys)}.\x1b[0m`);
    hasErrors = true;
  }

  // 2. Identical values count
  let identicalCount = 0;

  for (const key of englishKeys) {
    if (!catalog[key]?.trim()) {
      continue;
    }

    if (catalog[key] === english[key]) {
      identicalCount++;
    }

    // 3. Format placeholder mismatch
    const tEn = tokenSignature(english[key]);
    const tLoc = tokenSignature(catalog[key]);
    if (JSON.stringify(tEn) !== JSON.stringify(tLoc)) {
      console.error(`\x1b[31m[${locale}] Error: Token mismatch for key "${key}"\x1b[0m`);
      console.error(`  en: ${english[key]}  Tokens: ${JSON.stringify(tEn)}`);
      console.error(`  ${locale}: ${catalog[key]}  Tokens: ${JSON.stringify(tLoc)}`);
      hasErrors = true;
    }
  }

  // Warn if identical translation count exceeds 15% of the total keys (approx > 150 out of 1050)
  const identicalRatio = identicalCount / englishKeys.length;
  if (identicalRatio > 0.15) {
    console.warn(`\x1b[33m[${locale}] Warning: High number of identical translations: ${identicalCount}/${englishKeys.length} (${(identicalRatio * 100).toFixed(1)}%)\x1b[0m`);
  }
}

if (hasErrors) {
  console.error("\n\x1b[31mApp locale checks failed.\x1b[0m");
  process.exit(1);
}

console.log(`\n\x1b[32mApp locales OK: Checked ${checkedCount} catalogs against ${englishKeys.length} English keys.\x1b[0m`);

function assertEqual(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assertNotEqual(actual, expected, label) {
  if (JSON.stringify(actual) === JSON.stringify(expected)) {
    throw new Error(`${label}: signatures unexpectedly match`);
  }
}
