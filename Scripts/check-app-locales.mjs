#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const resources = path.join(repoRoot, "Sources/CodexBar/Resources");
const english = readCatalog("en");
const englishKeys = Object.keys(english).sort();

function readCatalog(locale) {
  const file = path.join(resources, `${locale}.lproj/Localizable.strings`);
  if (!fs.existsSync(file)) return null;
  const output = execFileSync("plutil", ["-convert", "json", "-o", "-", file], { encoding: "utf8" });
  return JSON.parse(output);
}

function tokens(value) {
  // Exclude explicit `%%` which don't require parameters
  const withoutEscapedPercents = value.replace(/%%/g, "");
  const printfRaw = withoutEscapedPercents.match(/%(?:\d+\$)?(?:\.\d+)?(?:@|d|f)/g) ?? [];
  // Normalize printf tokens so positional specifiers like %1$@ are compared as %@
  const printf = printfRaw.map(t => t.replace(/\d+\$/, ""));

  const swift = value.match(/\\\([^)]*\)/g) ?? [];
  return [...printf, ...swift].sort();
}

let hasErrors = false;
let checkedCount = 0;

for (const directory of fs.readdirSync(resources).filter((name) => name.endsWith(".lproj"))) {
  const locale = directory.replace(/\.lproj$/, "");
  if (locale === "en" || locale === "Base") continue;
  
  const catalog = readCatalog(locale);
  if (!catalog) continue;

  checkedCount++;
  const catalogKeys = Object.keys(catalog);
  
  // 1. Missing keys
  const missingKeys = englishKeys.filter(k => !catalogKeys.includes(k));
  if (missingKeys.length > 0) {
    console.warn(`\x1b[33m[${locale}] Warning: Missing ${missingKeys.length} keys.\x1b[0m`);
  }

  // 2. Identical values count
  let identicalCount = 0;
  let mismatchedTokensCount = 0;

  for (const key of englishKeys) {
    if (!catalog[key]) continue;
    
    if (catalog[key] === english[key]) {
      identicalCount++;
    }

    // 3. Format placeholder mismatch
    const tEn = tokens(english[key]);
    const tLoc = tokens(catalog[key]);
    if (JSON.stringify(tEn) !== JSON.stringify(tLoc)) {
      console.error(`\x1b[31m[${locale}] Error: Token mismatch for key "${key}"\x1b[0m`);
      console.error(`  en: ${english[key]}  Tokens: ${JSON.stringify(tEn)}`);
      console.error(`  ${locale}: ${catalog[key]}  Tokens: ${JSON.stringify(tLoc)}`);
      mismatchedTokensCount++;
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
  console.error(`\n\x1b[31mi18n checks failed due to token mismatches.\x1b[0m`);
  process.exit(1);
} else {
  console.log(`\n\x1b[32mApp locales OK: Checked ${checkedCount} catalogs, ${englishKeys.length} keys each.\x1b[0m`);
}

