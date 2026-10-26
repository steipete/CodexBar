#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { localeCatalog, localeMessages } from "../docs/site-locales.mjs";
import { checkSocialCard } from "./social-card.mjs";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
checkSocialCard(repoRoot);
const indexHtml = fs.readFileSync(path.join(repoRoot, "docs/index.html"), "utf8");
const providerSource = fs.readFileSync(path.join(repoRoot, "Sources/CodexBarCore/Providers/Providers.swift"), "utf8");
const providerEnumBody = providerSource.match(/public enum UsageProvider:[^{]+\{([\s\S]*?)\n\}/)?.[1];
assert(providerEnumBody, "could not locate UsageProvider cases");
const providerIDs = [...providerEnumBody.matchAll(/^\s*case\s+(\w+)\s*$/gm)].map((match) => match[1]);
assert(providerIDs.length > 0, "UsageProvider must define at least one provider");
assertEqual(new Set(providerIDs).size, providerIDs.length, "UsageProvider IDs");
const providerCount = providerIDs.length;

const publicCountFiles = [
  ["README.md", `alt="CodexBar — every AI coding limit in your menu bar. ${providerCount} providers."`],
  ["docs/providers.md", `CodexBar currently registers ${providerCount} provider IDs.`],
  ["docs/social.html", `<strong>${providerCount} providers</strong>`],
  ["docs/llms.txt", `across ${providerCount} providers`],
];
for (const [relativePath, expectedText] of publicCountFiles) {
  const contents = fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
  assert(contents.includes(expectedText), `${relativePath} must advertise ${providerCount} providers`);
}
assert(
  indexHtml.includes(`across ${providerCount} providers`),
  `index metadata must advertise ${providerCount} providers`,
);
assert(
  indexHtml.includes(`across ${providerCount} AI coding providers`),
  `index social metadata must advertise ${providerCount} providers`,
);
assert(
  indexHtml.includes(`>${providerCount} providers,{mobileBreak}one menu bar</span>`),
  `index provider heading must advertise ${providerCount} providers`,
);

assert(!indexHtml.includes("cdn.tailwindcss.com"), "site must not load Tailwind from a runtime CDN");
for (const match of indexHtml.matchAll(/<link rel="stylesheet" href="\.\/([^"?]+)(?:\?[^"']*)?"/g)) {
  assert(fs.existsSync(path.join(repoRoot, "docs", match[1])), `missing local stylesheet ${match[1]}`);
}
const expectedCodes = [
  "en",
  "zh-CN",
  "zh-TW",
  "ja-JP",
  "es",
  "pt-BR",
  "ko",
  "de",
  "fr",
  "ar",
  "it",
  "vi",
  "nl",
  "tr",
  "uk",
  "ru",
  "id",
  "pl",
  "fa",
  "th",
  "gl",
  "ca",
  "sv",
];
const catalogCodes = localeCatalog.map((locale) => locale.code);
const appLanguageSource = fs.readFileSync(
  path.join(repoRoot, "Sources/CodexBar/Settings/PreferencesGeneralPane.swift"),
  "utf8",
);

assertEqual(catalogCodes, expectedCodes, "locale catalog");
assertEqual(
  localeCatalog.filter((locale) => locale.direction === "rtl").map((locale) => locale.code),
  ["ar", "fa"],
  "RTL locale catalog",
);
const appLanguageEnumBody = appLanguageSource.match(/enum AppLanguage:[^{]+\{([\s\S]*?)\n\}/)?.[1];
assert(appLanguageEnumBody, "could not locate AppLanguage cases");
const appCatalogCodes = [...appLanguageEnumBody.matchAll(/case \w+ = "([^"]+)"/g)]
  .map((match) => match[1])
  .filter(Boolean)
  .map((code) => ({ "zh-Hans": "zh-CN", "zh-Hant": "zh-TW", ja: "ja-JP" })[code] ?? code);
assertEqual(appCatalogCodes, expectedCodes, "app language catalog");

const englishKeys = Object.keys(localeMessages.en).sort();
for (const locale of localeCatalog) {
  const messages = localeMessages[locale.code];
  assert(messages, `missing messages for ${locale.code}`);
  assertEqual(Object.keys(messages).sort(), englishKeys, `${locale.code} message keys`);

  for (const key of ["meta.description", "meta.ogDescription", "providers.title"]) {
    // Provider names such as v0 can precede the provider count in translated metadata.
    const counts = [...messages[key].matchAll(/\b\d+\b/g)].map(Number);
    assertEqual(counts[0], providerCount, `${locale.code}.${key} provider count`);
  }

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

const siteJs = fs.readFileSync(path.join(repoRoot, "docs/site.js"), "utf8");
const hasLanguagePicker =
  indexHtml.includes('id="language-picker-list"') &&
  (indexHtml.includes("localeCatalog") || siteJs.includes("localeCatalog"));
assert(hasLanguagePicker, "site must include the language picker backed by localeCatalog");

for (const code of catalogCodes) {
  assert(indexHtml.includes(`href="https://codexbar.app/?lang=${code}"`), `missing hreflang URL for ${code}`);
}

const providerCards = [...indexHtml.matchAll(/<li class="provider-card"([^>]*)>([\s\S]*?)<\/li>/g)];
const listedProviderIDs = [];
for (const [, attrs, body] of providerCards) {
  const providerID = attrs.match(/data-provider="([^"]+)"/)?.[1];
  if (providerID) {
    listedProviderIDs.push(providerID);
    assert(!attrs.includes("hidden"), `registered provider ${providerID} must be visible`);
    const documentationPath = body.match(
      /href="https:\/\/github\.com\/steipete\/CodexBar\/blob\/main\/(docs\/[^"#]+\.md)"/,
    )?.[1];
    assert(documentationPath, `${providerID} must link to its provider documentation`);
    assert(
      !["docs/provider.md", "docs/providers.md"].includes(documentationPath),
      `${providerID} must link to its own setup guide`,
    );
    assert(
      fs.existsSync(path.join(repoRoot, documentationPath)),
      `missing provider documentation ${documentationPath}`,
    );
  } else {
    assert(
      body.includes('data-i18n="providers.yourProvider"'),
      "provider cards must identify their registered provider",
    );
  }
  if (!attrs.includes("hidden")) {
    assert(body.includes('class="provider-card-link"'), "provider cards must link to provider documentation");
    assert(body.includes('class="provider-logo'), "provider cards must use logo assets");
    for (const match of body.matchAll(/src="\.\/([^"]+)"/g)) {
      assert(fs.existsSync(path.join(repoRoot, "docs", match[1])), `missing provider logo asset ${match[1]}`);
    }
  }
}
assertEqual([...listedProviderIDs].sort(), [...providerIDs].sort(), "website provider coverage");

console.log(
  `app/site locales OK: ${catalogCodes.length} locales, ${englishKeys.length} site messages, ${providerCount} provider cards`,
);

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
