#!/usr/bin/env node
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// New providers opt into generated directory rows through their provider-owned documentation.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const check = process.argv.includes("--check");
const update = (file, transform) => {
  const before = fs.existsSync(path.join(root, file)) ? read(file) : "";
  const after = transform(before);
  if (check) assert.equal(before, after, `${file} is stale; run Scripts/regenerate-provider-docs.mjs`);
  else if (before !== after) fs.writeFileSync(path.join(root, file), after);
};
const body = read("Sources/CodexBarCore/Providers/Providers.swift").match(
  /public enum UsageProvider:[^{]+\{([\s\S]*?)\n\}/,
)[1];
const ids = [...body.matchAll(/^\s*case (\w+)$/gm)].map((match) => match[1]);
const count = ids.length;
assert(count > 0 && new Set(ids).size === count);
const entries = fs
  .readdirSync(path.join(root, "docs"))
  .filter((file) => file.endsWith(".md"))
  .flatMap((file) => {
    const front = read(`docs/${file}`).match(/^---\n([\s\S]*?)\n---/u)?.[1] ?? "";
    const field = (key) => front.match(new RegExp(`^${key}: (.+)$`, "m"))?.[1];
    const id = field("provider_id");
    if (!id) return [];
    assert(ids.includes(id), `Unregistered provider ${id}`);
    const entry = {
      id,
      file,
      name: field("provider_name"),
      source: field("provider_source"),
      scope: field("plugin_scope"),
    };
    assert(entry.name && entry.source && entry.scope);
    return [entry];
  })
  .sort((a, b) => ids.indexOf(a.id) - ids.indexOf(b.id));
const providerRoot = "Sources/CodexBarCore/Providers";
const descriptors = fs
  .readdirSync(path.join(root, providerRoot), { recursive: true })
  .filter((file) => file.endsWith("ProviderDescriptor.swift"))
  .map((file) => read(`${providerRoot}/${file}`));
for (const entry of entries) {
  const descriptor = descriptors.find((source) => source.includes(`id: .${entry.id},`));
  entry.color = descriptor?.match(/color: (?:ProviderColor|\.init)\(hex: 0x([A-Fa-f0-9]{6})\)/u)?.[1];
  assert(entry.color, `Missing hex branding for ${entry.id}`);
  entry.auth = descriptor.includes("webSource:") ? "cookies" : "apiKey";
  update(`docs/logos/${entry.id}.svg`, () => read(`Sources/CodexBar/Resources/ProviderIcon-${entry.id}.svg`));
}
const html = (value) => value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll('"', "&quot;");
const section = (text, lines) => {
  const start = "<!-- Generated provider additions: Scripts/regenerate-provider-docs.mjs -->";
  const end = "<!-- End generated provider additions -->";
  const generated = `${start}\n${lines.join("\n")}\n${end}`;
  assert(text.includes(start) && text.includes(end), "Missing generated provider section");
  return text.slice(0, text.indexOf(start)) + generated + text.slice(text.indexOf(end) + end.length);
};
update("README.md", (text) =>
  section(
    text.replace(/\d+ providers\."/u, `${count} providers."`),
    entries.map((entry) => `- [${entry.name}](docs/${entry.file}) — ${entry.source}`),
  ),
);
update("docs/providers.md", (text) =>
  section(text.replace(/currently registers \d+ provider IDs/u, `currently registers ${count} provider IDs`), [
    "",
    "| Provider | Source |",
    "|---|---|",
    ...entries.map((entry) => `| [${entry.name}](${entry.file}) | ${entry.source} |`),
    "",
  ]),
);
update("docs/social.html", (text) =>
  text.replace(/<strong>\d+ providers<\/strong>/u, `<strong>${count} providers</strong>`),
);
update("docs/index.html", (text) =>
  section(
    text.replace(/\d+(?= (?:AI coding )?providers)/gu, String(count)),
    entries.map(
      (entry) =>
        `          <li class="provider-card" data-provider="${entry.id}"><a class="provider-card-link" href="https://github.com/steipete/CodexBar/blob/main/docs/${entry.file}"><span class="provider-logo" style="--brand:#${entry.color};--icon:url('./logos/${entry.id}.svg')"><img src="./logos/${entry.id}.svg" alt="" loading="lazy" onerror="this.remove()" /></span><p><strong>${html(entry.name)}</strong><span data-i18n="auth.${entry.auth}">${entry.auth === "cookies" ? "Cookies" : "API key"}</span></p></a></li>`,
    ),
  ),
);
update("docs/site-locales.mjs", (text) =>
  text.replace(/("(?:meta\.description|meta\.ogDescription|providers\.title)": ")[^\n]+/gu, (line) =>
    line.replace(/\b\d{2,}\b/u, String(count)),
  ),
);
update("docs/plugin-conversion-matrix.md", (text) => {
  text = section(text, [
    "",
    "| Provider | Status | Engines | Scope |",
    "|---|---|---|---|",
    ...entries.map((entry) => `| ${entry.id} | \`cut-over\` | QuickJS + JavaScriptCore | ${entry.scope} |`),
    "",
  ]);
  const additions = [...text.split("## Additional plugin-first providers")[1].matchAll(/^\| [a-z0-9]+ \|/gm)].length;
  const audit = Number(text.match(/\| \*\*Audit total\*\* \| \*\*(\d+)\*\*/u)[1]);
  const unclassified = count - audit - additions;
  return text
    .replace(/registry now contains \d+ providers/u, `registry now contains ${count} providers`)
    .replace(
      /\d+ additional plugin-first rows, and \d+ providers/u,
      `${additions} additional plugin-first rows, and ${unclassified} providers`,
    )
    .replace(/\| Additional plugin-first providers \| \d+ \|/u, `| Additional plugin-first providers | ${additions} |`)
    .replace(
      /\| Registered providers not yet classified here \| \d+ \|/u,
      `| Registered providers not yet classified here | ${unclassified} |`,
    )
    .replace(/\| \*\*Registry total\*\* \| \*\*\d+\*\* \|/u, `| **Registry total** | **${count}** |`);
});
console.log(`Provider documentation ${check ? "current" : "generated"}: ${count} registered providers`);
