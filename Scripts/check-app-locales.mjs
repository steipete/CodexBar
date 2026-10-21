#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  hasPrintfArguments,
  pluralCatalogErrors,
  printfSignature,
  protectedLiteralErrors,
} from "./localization-formats.mjs";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const resources = path.join(repoRoot, "Sources/CodexBar/Resources");
const english = readCatalog("en");
const englishKeys = Object.keys(english).sort();
const strictLocales = ["ar", "ca", "fa", "th"];
// Catalogs that have reached full English-key coverage. New locales can remain
// warning-only while they are being bootstrapped, then join this list once complete.
const completeLocales = [
  "ar",
  "ca",
  "de",
  "es",
  "fa",
  "fr",
  "gl",
  "id",
  "it",
  "ja",
  "ko",
  "nl",
  "pl",
  "pt-BR",
  "ru",
  "sv",
  "th",
  "tr",
  "uk",
  "vi",
  "zh-Hans",
  "zh-Hant",
];
const languageKeys = ["language_arabic", "language_persian", "language_thai"];
const isTest = process.argv.includes("--test");

function readCatalog(locale) {
  const file = path.join(resources, `${locale}.lproj/Localizable.strings`);
  if (!fs.existsSync(file)) return null;
  const output = execFileSync("plutil", ["-convert", "json", "-o", "-", file], { encoding: "utf8" });
  return JSON.parse(output);
}

function tokenSignature(value, formatted = hasPrintfArguments(value)) {
  return { printf: formatted ? printfSignature(value) : {}, swift: swiftInterpolationTokens(value).sort() };
}

function formatKeyList(keys, limit = 12) {
  const shown = keys.slice(0, limit).join(", ");
  const remaining = keys.length - limit;
  return remaining > 0 ? `${shown}, ... +${remaining} more` : shown;
}

function blankKeys(catalog, referenceKeys) {
  return referenceKeys.filter((key) => Object.hasOwn(catalog, key) && !catalog[key]?.trim());
}

function literalSwiftKeys(source, marker) {
  const keys = [];
  const literal = String.raw`"(?:[^"\\]|\\.)*"`;
  const expressions = new RegExp(`${marker}\\s*(${literal}(?:\\s*\\+\\s*${literal})*)`, "g");
  for (const match of source.matchAll(expressions)) {
    if (match[1].includes("\\(")) continue;
    try {
      const parts = match[1].match(new RegExp(literal, "g"));
      keys.push(
        parts
          .map((part) =>
            JSON.parse(part.replace(/\\u\{([\da-f]+)\}/gi, (_, hex) => String.fromCodePoint(Number.parseInt(hex, 16)))),
          )
          .join(""),
      );
    } catch {
      // Swift raw/interpolated strings are checked at their presentation seams.
    }
  }
  return keys;
}

function swiftFiles(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) return swiftFiles(file);
    return entry.name.endsWith(".swift") && !/(?:Testing|NativeProof)/.test(entry.name) ? [file] : [];
  });
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
  assertEqual(literalSwiftKeys('L("first " + "second")', String.raw`\bL\(`), ["first second"], "concatenated keys");
  assertEqual(literalSwiftKeys(String.raw`L("value \\(name)")`, String.raw`\bL\(`), [], "dynamic keys");
  assertEqual(
    literalSwiftKeys('title: "API key", subtitle: "Help"', String.raw`\b(?:title|subtitle):`),
    ["API key", "Help"],
    "provider descriptors",
  );
  assertEqual(tokenSignature("%1$@ · %2$d"), tokenSignature("%2$d · %1$@"), "positional reorder");
  assertNotEqual(tokenSignature("%1$@ · %2$d"), tokenSignature("%1$d · %2$@"), "positional type swap");
  assertEqual(tokenSignature("%.0f%% used"), tokenSignature("%.0f%% verbraucht"), "escaped percent");
  assertNotEqual(tokenSignature("\\(name): \\(usage)"), tokenSignature("\\(name): \\(value)"), "Swift tokens");
  assertEqual(
    tokenSignature("\\(self.store.metadata(for: self.provider).displayName) failed"),
    tokenSignature("Fehler: \\(self.store.metadata(for: self.provider).displayName)"),
    "nested Swift interpolation",
  );
  assertNotEqual(
    tokenSignature("\\(self.store.metadata(for: self.provider).displayName) failed"),
    tokenSignature("\\(self.store.metadata(for: self.provider) failed"),
    "truncated Swift interpolation",
  );
  assertEqual(formatKeyList(["alpha", "beta"]), "alpha, beta", "short key list");
  assertEqual(formatKeyList(["alpha", "beta", "gamma", "delta"], 2), "alpha, beta, ... +2 more", "truncated key list");
  assertEqual(
    blankKeys({ alpha: "", beta: "  ", gamma: "ok" }, ["alpha", "beta", "gamma", "delta"]),
    ["alpha", "beta"],
    "blank keys",
  );
  assertEqual([...new Set(completeLocales)], completeLocales, "unique complete locales");
  assertEqual(
    strictLocales.filter((locale) => !completeLocales.includes(locale)),
    [],
    "strict locales are complete locales",
  );
  console.log("app locale checker tests OK");
  process.exit(0);
}

let hasErrors = false;
let checkedCount = 0;

const pluralFile = path.join(resources, "en.lproj/Localizable.stringsdict");
const englishPlurals = JSON.parse(
  execFileSync("plutil", ["-convert", "json", "-o", "-", pluralFile], { encoding: "utf8" }),
);
const pluralKeys = Object.keys(englishPlurals);
for (const directory of fs.readdirSync(resources).filter((name) => name.endsWith(".lproj") && name !== "Base.lproj")) {
  const file = path.join(resources, directory, "Localizable.stringsdict");
  if (!fs.existsSync(file)) {
    console.error(`[${directory}] Missing plural dictionary`);
    hasErrors = true;
    continue;
  }
  const catalog = JSON.parse(execFileSync("plutil", ["-convert", "json", "-o", "-", file], { encoding: "utf8" }));
  for (const error of pluralCatalogErrors(catalog, englishPlurals)) {
    console.error(`[${directory}] ${error}`);
    hasErrors = true;
  }
}
for (const key of englishKeys) {
  try {
    tokenSignature(english[key], hasPrintfArguments(key) || hasPrintfArguments(english[key]));
  } catch (error) {
    console.error(`[en] Invalid format for ${JSON.stringify(key)}: ${error.message}`);
    hasErrors = true;
  }
}
const knownKeys = new Set([...englishKeys, ...pluralKeys]);
const widgetKeys = new Set(
  JSON.parse(fs.readFileSync(path.join(repoRoot, "Scripts/widget-localization-keys.json"), "utf8")),
);
for (const directory of ["Sources/CodexBar", "Sources/CodexBarWidget", "Sources/CodexBarCore/Providers"]) {
  for (const file of swiftFiles(path.join(repoRoot, directory))) {
    const source = fs.readFileSync(file, "utf8");
    const keys = literalSwiftKeys(source, String.raw`\b(?:L|W)\(`);
    if (directory !== "Sources/CodexBarCore/Providers") {
      const rawUI = literalSwiftKeys(
        source,
        String.raw`(?:\b(?:Text|Button|Toggle|Label|SettingsRowLabel|TextField|SecureField)\(|\.(?:help|accessibilityLabel|alert)\()`,
      );
      for (const key of rawUI) {
        if (key !== "CodexBar" && /[A-Za-z]/.test(key)) {
          console.error(`${path.relative(repoRoot, file)}: unlocalized UI literal ${JSON.stringify(key)}`);
          hasErrors = true;
        }
      }
    }
    if (directory === "Sources/CodexBarWidget") {
      for (const key of literalSwiftKeys(source, String.raw`\bW\(`)) {
        if (key && !widgetKeys.has(key)) {
          console.error(`${path.relative(repoRoot, file)}: missing widget resource key ${JSON.stringify(key)}`);
          hasErrors = true;
        }
      }
    }
    if (file.includes(`${path.sep}Providers${path.sep}`)) {
      const isCore = file.includes(`${path.sep}CodexBarCore${path.sep}`);
      const marker =
        !isCore || file.endsWith("Descriptor.swift")
          ? String.raw`\b(?:title|subtitle|placeholder|sessionLabel|weeklyLabel|opusLabel|creditsHint|noDataMessage):`
          : String.raw`\btitle:`;
      keys.push(...literalSwiftKeys(source, marker));
    }
    for (const key of new Set(keys)) {
      if (!key || knownKeys.has(key)) continue;
      console.error(`${path.relative(repoRoot, file)}: missing English catalog key ${JSON.stringify(key)}`);
      hasErrors = true;
    }
  }
}

for (const completeLocale of completeLocales) {
  const dirPath = path.join(resources, `${completeLocale}.lproj`);
  if (!fs.existsSync(dirPath)) {
    console.error(`\x1b[31mError: Required complete locale catalog is missing: ${completeLocale}.lproj\x1b[0m`);
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
    if (completeLocales.includes(locale)) {
      console.error(
        `\x1b[31m[${locale}] Error: Missing ${missingKeys.length} keys in complete locale: ${missingKeyList}.\x1b[0m`,
      );
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
      `\x1b[31m[${locale}] Error: Blank values for ${emptyKeys.length} keys: ${formatKeyList(emptyKeys)}.\x1b[0m`,
    );
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
    for (const error of protectedLiteralErrors(key, catalog[key], english[key])) {
      console.error(`[${locale}] ${error}`);
      hasErrors = true;
    }
    try {
      const formatted = hasPrintfArguments(key) || hasPrintfArguments(english[key]);
      const tEn = tokenSignature(english[key], formatted);
      const tLoc = tokenSignature(catalog[key], formatted);
      if (JSON.stringify(tEn) !== JSON.stringify(tLoc)) {
        console.error(`\x1b[31m[${locale}] Error: Token mismatch for key "${key}"\x1b[0m`);
        console.error(`  en: ${english[key]}  Tokens: ${JSON.stringify(tEn)}`);
        console.error(`  ${locale}: ${catalog[key]}  Tokens: ${JSON.stringify(tLoc)}`);
        hasErrors = true;
      }
    } catch (error) {
      console.error(`[${locale}] Invalid format for ${JSON.stringify(key)}: ${error.message}`);
      hasErrors = true;
    }
  }

  // Warn if identical translation count exceeds 15% of the total keys (approx > 150 out of 1050)
  const identicalRatio = identicalCount / englishKeys.length;
  if (identicalRatio > 0.15) {
    console.warn(
      `\x1b[33m[${locale}] Warning: High number of identical translations: ${identicalCount}/${englishKeys.length} (${(identicalRatio * 100).toFixed(1)}%)\x1b[0m`,
    );
  }
}

if (hasErrors) {
  console.error("\n\x1b[31mApp locale checks failed.\x1b[0m");
  process.exit(1);
}

console.log(
  `\n\x1b[32mApp locales OK: Checked ${checkedCount} catalogs against ${englishKeys.length} English keys.\x1b[0m`,
);

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
