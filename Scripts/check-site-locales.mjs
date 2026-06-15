#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { localeCatalog, localeMessages } from "../docs/site-locales.mjs";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const indexHtml = fs.readFileSync(path.join(repoRoot, "docs/index.html"), "utf8");
const expectedCodes = [
  "en", "zh-CN", "zh-TW", "ja-JP", "es", "pt-BR", "ko", "de", "fr", "ar", "it",
  "vi", "nl", "tr", "uk", "id", "pl", "fa", "th", "ca", "sv",
];
const catalogCodes = localeCatalog.map((locale) => locale.code);
const appLanguageSource = fs.readFileSync(
  path.join(repoRoot, "Sources/CodexBar/PreferencesGeneralPane.swift"),
  "utf8",
);

assertEqual(catalogCodes, expectedCodes, "locale catalog");
assertEqual(
  localeCatalog.filter((locale) => locale.direction === "rtl").map((locale) => locale.code),
  ["ar", "fa"],
  "RTL locale catalog");
const appCatalogCodes = [...appLanguageSource.matchAll(/case \w+ = "([^"]+)"/g)]
  .map((match) => match[1])
  .filter(Boolean)
  .map((code) => ({ "zh-Hans": "zh-CN", "zh-Hant": "zh-TW", ja: "ja-JP" })[code] ?? code);
assertEqual(appCatalogCodes, expectedCodes, "app language catalog");

const englishKeys = Object.keys(localeMessages.en).sort();
for (const locale of localeCatalog) {
  const messages = localeMessages[locale.code];
  assert(messages, `missing messages for ${locale.code}`);
  assertEqual(Object.keys(messages).sort(), englishKeys, `${locale.code} message keys`);

  for (const key of englishKeys) {
    assert(messages[key].trim(), `${locale.code}.${key} is blank`);
    assertEqual(tokens(messages[key]), tokens(localeMessages.en[key]), `${locale.code}.${key} tokens`);
  }
}

const referencedKeys = new Set();
for (const match of indexHtml.matchAll(/data-i18n(?:-rich|-aria-label|-title|-alt)?="([^"]+)"/g)) {
  referencedKeys.add(match[1]);
}
for (const key of referencedKeys) {
  assert(englishKeys.includes(key), `index.html references unknown locale key ${key}`);
}

const optionMatches = [...indexHtml.matchAll(/<option value="([^"]+)">([^<]+)<\/option>/g)];
assertEqual(optionMatches.map((match) => match[1]), catalogCodes, "language selector locales");
assertEqual(optionMatches.map((match) => match[2]), localeCatalog.map((locale) => locale.name), "language selector labels");

for (const code of catalogCodes) {
  assert(indexHtml.includes(`href="https://codexbar.app/?lang=${code}"`), `missing hreflang URL for ${code}`);
}

const providerCards = [...indexHtml.matchAll(/<a class="provider([^"]*)"[^>]*>([\s\S]*?)<\/a>/g)];
for (const [, classes, body] of providerCards) {
  if (!classes.split(/\s+/).includes("add")) {
    assert(body.includes('class="chip-logo'), "provider cards must use logo assets instead of text placeholders");
  }
}

console.log(`app/site locales OK: ${catalogCodes.length} locales, ${englishKeys.length} site messages`);

function tokens(value) {
  return [...value.matchAll(/\{([^}]+)\}/g)].map((match) => match[1]).sort();
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function assertEqual(actual, expected, label) {
  const actualJSON = JSON.stringify(actual);
  const expectedJSON = JSON.stringify(expected);
  if (actualJSON !== expectedJSON) {
    throw new Error(`${label}: expected ${expectedJSON}, got ${actualJSON}`);
  }
}
