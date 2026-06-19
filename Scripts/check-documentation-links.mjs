#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

const readme = readText("README.md");
const readmeLinks = [
  ...markdownLinks(readme),
  ...markdownImageLinks(readme),
  ...htmlLinks(readme),
].filter(isRepositoryDocReference);

assert(readmeLinks.length > 0, "README.md has no local documentation links");
for (const link of readmeLinks) validateLocalDocLink(link);

const providerLinks = inlineCodeDocLinks(readText("docs/providers.md"));
assert(providerLinks.length > 0, "docs/providers.md has no provider detail links");
for (const link of providerLinks) validateLocalDocLink(link);

console.log(`documentation links OK: ${readmeLinks.length + providerLinks.length} local links`);

function readText(relativePath) {
  return fs.readFileSync(path.join(repoRoot, relativePath), "utf8");
}

function markdownLinks(markdown) {
  const source = markdownTextOutsideCode(markdown);
  const links = [];
  const inlinePattern = /(?<!!)\[(?:\\.|[^\]\\])+\]\(\s*(?:<([^>\n]+)>|([^\s)]+))(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^)\n]*\)))?\s*\)/g;
  for (const match of source.matchAll(inlinePattern)) {
    links.push(encodeSpaces(match[1] ?? match[2]));
  }

  const referencePattern = /^\s*\[[^\]\n]+]:\s*(?:<([^>\n]+)>|([^\s]+))/gm;
  for (const match of source.matchAll(referencePattern)) {
    links.push(encodeSpaces(match[1] ?? match[2]));
  }
  return links;
}

function markdownImageLinks(markdown) {
  const source = markdownTextOutsideCode(markdown);
  const pattern = /!\[(?:\\.|[^\]\\])*\]\(\s*(?:<([^>\n]+)>|([^\s)]+))(?:\s+(?:"[^"\n]*"|'[^'\n]*'|\([^)\n]*\)))?\s*\)/g;
  return [...source.matchAll(pattern)].map((match) => match[1] ?? match[2]);
}

function htmlLinks(markdown) {
  const source = markdownTextOutsideCode(markdown);
  const pattern = /<\s*(?:a|img)\b[^>]*?\b(?:href|src)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/gi;
  return [...source.matchAll(pattern)].map((match) => match[1] ?? match[2] ?? match[3]);
}

function inlineCodeDocLinks(markdown) {
  return markdown.split("\n").flatMap((line) => {
    const trimmed = line.trim();
    const prefix = "- Details: `";
    if (!trimmed.startsWith(prefix)) return [];
    const rest = trimmed.slice(prefix.length);
    const end = rest.indexOf("`");
    return end === -1 ? [] : [rest.slice(0, end)];
  });
}

function validateLocalDocLink(rawLink) {
  const { absolutePath, fragment } = localDocPath(rawLink);
  assert(fs.existsSync(absolutePath), `missing documentation target: ${rawLink}`);

  if (path.extname(absolutePath).toLowerCase() !== ".md" || !fragment) return;
  const anchors = markdownHeadingAnchors(readText(path.relative(repoRoot, absolutePath)));
  assert(anchors.has(fragment), `missing documentation anchor: ${rawLink}`);
}

function isRepositoryDocReference(rawLink) {
  const parsed = parseRelativeURL(rawLink);
  if (!parsed || parsed.protocol || parsed.host) return false;
  let pathname = parsed.pathname;
  while (pathname.startsWith("./")) pathname = pathname.slice(2);
  return pathname === "docs" || pathname.startsWith("docs/");
}

function localDocPath(rawLink) {
  const parsed = parseRelativeURL(rawLink);
  assert(parsed && !parsed.protocol && !parsed.host && parsed.pathname, `invalid documentation URL: ${rawLink}`);

  const decodedPath = decodeURIComponent(parsed.pathname);
  const absolutePath = path.resolve(repoRoot, decodedPath);
  const docsRoot = path.resolve(repoRoot, "docs");
  assert(
    absolutePath === docsRoot || absolutePath.startsWith(`${docsRoot}${path.sep}`),
    `documentation link escapes docs root: ${rawLink}`,
  );
  return { absolutePath, fragment: parsed.hash ? decodeURIComponent(parsed.hash.slice(1)) : "" };
}

function parseRelativeURL(rawLink) {
  try {
    const parsed = new URL(rawLink, "relative://repo/");
    const isRelative = parsed.protocol === "relative:" && parsed.host === "repo";
    return {
      protocol: isRelative ? "" : parsed.protocol,
      host: isRelative ? "" : parsed.host,
      pathname: isRelative ? parsed.pathname.replace(/^\//, "") : parsed.pathname,
      hash: parsed.hash,
    };
  } catch {
    return null;
  }
}

function markdownHeadingAnchors(markdown) {
  const occurrences = new Map();
  const anchors = new Set();
  const source = markdownTextOutsideFencedCode(markdown);
  for (const line of source.split("\n")) {
    const trimmed = line.replace(/^[ \t]+/, "");
    const match = /^(#{1,6})\s+(.+?)\s*$/.exec(trimmed);
    if (!match) continue;
    const base = markdownHeadingSlug(match[2]);
    if (!base) continue;
    const occurrence = occurrences.get(base) ?? 0;
    anchors.add(occurrence === 0 ? base : `${base}-${occurrence}`);
    occurrences.set(base, occurrence + 1);
  }
  return anchors;
}

function markdownHeadingSlug(heading) {
  const text = removeMarkdownFormatting(heading).toLowerCase();
  let slug = "";
  for (const char of text) {
    if (/[\p{Letter}\p{Number}_-]/u.test(char)) {
      slug += char;
    } else if (/\s/u.test(char)) {
      slug += "-";
    }
  }
  return slug;
}

function removeMarkdownFormatting(text) {
  return text
    .replace(/`([^`]*)`/g, "$1")
    .replace(/\[([^\]]+)]\([^)]+\)/g, "$1")
    .replace(/[*_~]/g, "");
}

function markdownTextOutsideCode(markdown) {
  return markdownTextOutsideFencedCode(markdown)
    .split("\n")
    .map(removeInlineCode)
    .join("\n");
}

function markdownTextOutsideFencedCode(markdown) {
  let fence = null;
  return markdown.split("\n").map((line) => {
    if (fence) {
      if (isClosingFence(line, fence.marker, fence.count)) fence = null;
      return "";
    }
    const openingFence = parseOpeningFence(line);
    if (openingFence) {
      fence = openingFence;
      return "";
    }
    return line;
  }).join("\n");
}

function parseOpeningFence(line) {
  const match = /^( {0,3})([`~]{3,})(.*)$/.exec(line);
  if (!match) return null;
  const marker = match[2][0];
  if (marker === "`" && match[3].includes("`")) return null;
  return { marker, count: match[2].length };
}

function isClosingFence(line, marker, minimumCount) {
  const escaped = marker === "`" ? "`" : "~";
  const pattern = new RegExp(`^ {0,3}${escaped}{${minimumCount},}\\s*$`);
  return pattern.test(line);
}

function removeInlineCode(line) {
  return line.replace(/(?<!`)(`+)(?!`)(.*?)(?<!`)\1(?!`)/g, "");
}

function encodeSpaces(value) {
  return value.replaceAll(" ", "%20");
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}
