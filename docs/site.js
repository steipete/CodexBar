import { localeCatalog, localeMessages } from "./site-locales.mjs";

const root = document.documentElement;
const toggle = document.querySelector(".theme-toggle");
const languageSelect = document.querySelector(".language-select");
const metaTheme = document.querySelector('meta[name="theme-color"]');
const metaDescription = document.querySelector('meta[name="description"]');
const metaOgDescription = document.querySelector('meta[property="og:description"]');
const media = window.matchMedia("(prefers-color-scheme: dark)");
const supportedLocales = new Set(localeCatalog.map((locale) => locale.code));
const rtlLocales = new Set(localeCatalog.filter((locale) => locale.direction === "rtl").map((locale) => locale.code));
let activeMessages = localeMessages.en;

function normalizeLocale(value) {
  if (!value) return null;

  const lower = value.toLowerCase();
  const aliases = {
    "zh-cn": "zh-CN",
    "zh-hans": "zh-CN",
    "zh-hant": "zh-TW",
    "zh-hk": "zh-TW",
    "zh-tw": "zh-TW",
    ja: "ja-JP",
    pt: "pt-BR",
    "pt-br": "pt-BR",
  };
  if (aliases[lower]) return aliases[lower];

  return localeCatalog.find((locale) =>
    locale.code.toLowerCase() === lower || lower.startsWith(`${locale.code.toLowerCase()}-`))?.code ?? null;
}

function selectedLocale() {
  const fromDocument = normalizeLocale(root.dataset.locale);
  if (fromDocument) return fromDocument;

  try {
    const queryLocale = normalizeLocale(new URLSearchParams(location.search).get("lang"));
    if (queryLocale) return queryLocale;
    const storedLocale = normalizeLocale(localStorage.getItem("codexbar-language"));
    if (storedLocale) return storedLocale;
  } catch (_) {}

  for (const language of navigator.languages || [navigator.language]) {
    const locale = normalizeLocale(language);
    if (locale) return locale;
  }
  return "en";
}

function message(key) {
  return activeMessages[key] || localeMessages.en[key] || key;
}

function applyLocale(locale) {
  const resolved = supportedLocales.has(locale) ? locale : "en";
  activeMessages = { ...localeMessages.en, ...localeMessages[resolved] };

  root.lang = resolved;
  root.dir = rtlLocales.has(resolved) ? "rtl" : "ltr";
  root.dataset.locale = resolved;
  if (languageSelect) languageSelect.value = resolved;

  document.title = message("meta.title");
  metaDescription?.setAttribute("content", message("meta.description"));
  metaOgDescription?.setAttribute("content", message("meta.ogDescription"));

  document.querySelectorAll("[data-i18n]").forEach((element) => {
    element.textContent = message(element.dataset.i18n);
  });
  document.querySelectorAll("[data-i18n-rich]").forEach((element) => {
    renderRichMessage(element, message(element.dataset.i18nRich));
  });
  applyAttributeMessages("data-i18n-aria-label", "aria-label");
  applyAttributeMessages("data-i18n-title", "title");
  applyAttributeMessages("data-i18n-alt", "alt");
  updateThemeUI();
}

function applyAttributeMessages(dataAttribute, targetAttribute) {
  document.querySelectorAll(`[${dataAttribute}]`).forEach((element) => {
    element.setAttribute(targetAttribute, message(element.getAttribute(dataAttribute)));
  });
}

function renderRichMessage(element, value) {
  const fragment = document.createDocumentFragment();
  const tokenPattern = /\{([a-zA-Z][a-zA-Z0-9]*)\}/g;
  let cursor = 0;
  let match;

  while ((match = tokenPattern.exec(value)) !== null) {
    fragment.append(document.createTextNode(value.slice(cursor, match.index)));
    fragment.append(richToken(match[1]));
    cursor = match.index + match[0].length;
  }
  fragment.append(document.createTextNode(value.slice(cursor)));
  element.replaceChildren(fragment);
}

function richToken(name) {
  const codeTokens = {
    cask: "brew install --cask steipete/tap/codexbar",
    codexbar: "codexbar",
    linuxCommand: "brew install steipete/tap/codexbar",
    upgrade: "brew upgrade",
  };
  if (codeTokens[name]) {
    const code = document.createElement("code");
    code.textContent = codeTokens[name];
    return code;
  }
  if (name === "releases") {
    const link = document.createElement("a");
    link.href = "https://github.com/steipete/CodexBar/releases/latest";
    link.textContent = "GitHub Releases";
    return link;
  }
  if (name === "issue") {
    const link = document.createElement("a");
    link.href = "https://github.com/steipete/CodexBar/issues/12";
    link.textContent = "issue #12";
    return link;
  }

  return document.createTextNode(`{${name}}`);
}

function queryTheme() {
  try {
    const value = new URLSearchParams(location.search).get("theme");
    return value === "light" || value === "dark" ? value : null;
  } catch (_) {
    return null;
  }
}

function storedTheme() {
  try {
    return localStorage.getItem("codexbar-theme");
  } catch (_) {
    return null;
  }
}

function effectiveTheme() {
  return root.dataset.theme || (media.matches ? "dark" : "light");
}

function updateThemeImages(theme) {
  document.querySelectorAll("img[data-dark-src]").forEach((image) => {
    if (!image.dataset.lightSrc) image.dataset.lightSrc = image.getAttribute("src");
    image.setAttribute("src", theme === "dark" ? image.dataset.darkSrc : image.dataset.lightSrc);
  });
}

function updateThemeUI() {
  const theme = effectiveTheme();
  updateThemeImages(theme);
  if (toggle) {
    const label = message(theme === "dark" ? "theme.toLight" : "theme.toDark");
    toggle.setAttribute("aria-pressed", theme === "dark" ? "true" : "false");
    toggle.setAttribute("aria-label", label);
    toggle.title = label;
  }
  metaTheme?.setAttribute("content", theme === "dark" ? "#0a0a0c" : "#fbfbfc");
}

toggle?.addEventListener("click", () => {
  const next = effectiveTheme() === "dark" ? "light" : "dark";
  root.dataset.theme = next;
  try {
    localStorage.setItem("codexbar-theme", next);
  } catch (_) {}
  updateThemeUI();
});

media.addEventListener?.("change", () => {
  if (!queryTheme() && !storedTheme()) updateThemeUI();
});

languageSelect?.addEventListener("change", () => {
  const locale = normalizeLocale(languageSelect.value) || "en";
  try {
    localStorage.setItem("codexbar-language", locale);
    const url = new URL(location.href);
    url.searchParams.set("lang", locale);
    history.replaceState(null, "", url);
  } catch (_) {}
  applyLocale(locale);
});

const copyButton = document.querySelector(".brew-copy");
copyButton?.addEventListener("click", () => {
  const text = document.getElementById("brew-cmd")?.textContent;
  if (!text || !navigator.clipboard) return;
  navigator.clipboard.writeText(text).then(() => {
    copyButton.classList.add("copied");
    copyButton.setAttribute("aria-label", message("clipboard.copied"));
    setTimeout(() => {
      copyButton.classList.remove("copied");
      copyButton.setAttribute("aria-label", message("clipboard.copy"));
    }, 1500);
  });
});

applyLocale(selectedLocale());
