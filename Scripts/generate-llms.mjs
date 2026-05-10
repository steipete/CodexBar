#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const docsDir = path.join(repoRoot, "docs");
const cname = fs.readFileSync(path.join(docsDir, "CNAME"), "utf8").trim();
const origin = "https://" + cname;
const productName = "CodexBar";
const productDescription = "CodexBar shows OpenAI Codex and Claude Code usage limits in the macOS menu bar.";
const source = "https://github.com/steipete/CodexBar";

const pages = allHtml(docsDir)
  .map((file) => {
    const rel = path.relative(docsDir, file).replaceAll(path.sep, "/");
    if (rel === "404.html" || rel === "social.html") return null;
    const html = fs.readFileSync(file, "utf8");
    return {
      rel,
      title: textContent(html.match(/<title[^>]*>([\s\S]*?)<\/title>/i)?.[1]) || titleize(path.basename(rel, ".html")),
      description: attr(html.match(/<meta\s+name=["']description["']\s+content=["']([^"']*)["'][^>]*>/i)?.[1] || ""),
    };
  })
  .filter(Boolean)
  .sort((a, b) => (a.rel === "index.html" ? -1 : b.rel === "index.html" ? 1 : a.rel.localeCompare(b.rel)));

const lines = [
  "# " + productName,
  "",
  productDescription,
  "",
  "Canonical documentation:",
  ...pages.map((page) => "- " + page.title + ": " + pageUrl(page.rel) + (page.description ? " - " + page.description : "")),
  "",
  "Source: " + source,
  "",
  "Guidance for agents:",
  "- Prefer the canonical documentation URLs above over README excerpts or package metadata.",
  "- Fetch only the pages needed for the current task; this is an index, not a full-site corpus.",
  "",
];

fs.writeFileSync(path.join(docsDir, "llms.txt"), lines.join("\n"), "utf8");
console.log("wrote " + path.relative(repoRoot, path.join(docsDir, "llms.txt")));

function allHtml(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.name === "node_modules" || entry.name.startsWith(".")) return [];
    if (entry.isDirectory()) return allHtml(full);
    return entry.name.endsWith(".html") ? [full] : [];
  });
}

function pageUrl(rel) {
  return rel === "index.html" ? origin + "/" : origin + "/" + rel;
}

function textContent(value) {
  return attr(value || "").replace(/<[^>]+>/g, "").replace(/\s+/g, " ").trim();
}

function attr(value) {
  return String(value || "")
    .replace(/&mdash;/g, "-")
    .replace(/&amp;/g, "&")
    .replace(/&nbsp;/g, " ")
    .replace(/&#39;/g, "'")
    .replace(/&quot;/g, '"')
    .trim();
}

function titleize(input) {
  return input.replaceAll("-", " ").replace(/\b\w/g, (m) => m.toUpperCase());
}
