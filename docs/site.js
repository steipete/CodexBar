import { localeCatalog, localeMessages } from './site-locales.mjs';

const root = document.documentElement;
let activeMessages = localeMessages.en;

const HERO_MOBILE_MAX = 768;
const HERO_TABLET_MAX = 1023;
const HERO_DESKTOP_MIN = 1024;
const MOCKUP_SCREEN_MARGIN_RIGHT = 50;
const MOCKUP_SCREEN_MARGIN_RIGHT_TABLET = 15;
const MOCKUP_ARTBOARD_RATIO = 1.18;
/* Tablet MacBook X tune @ 1001px, scale 1.2 */
const HERO_TABLET_MOCKUP_X_CORRECTION = -9;

const HERO_MOBILE_MOCKUP_TUNE_SCALE = 0.99;
/* Mobile MacBook X tune @ 490px, right-anchored full-bleed stage */
const HERO_MOBILE_MOCKUP_X_CORRECTION = -32;

const HERO_ARTBOARD = { width: 6111, height: 3239 };

/* Figma @ 6111×3239 — menubar anchor 130 top / 150 right; scale 0.94 (desktop) / 0.82 (mobile) */
const HERO_MENUBAR_BASE = {
  figmaTop: 130,
  figmaRight: 150,
  scale: 0.94,
  mobileScale: 0.82,
  iconScale: 1.28,
};

/* Visual correction vs computed base (tune @ 1920 → 5.25%, 3.8%, scale ×1.55) */
const HERO_MENUBAR_CORRECTION = {
  top: 5.25 / ((HERO_MENUBAR_BASE.figmaTop / HERO_ARTBOARD.height) * 100),
  right: 3.8 / ((HERO_MENUBAR_BASE.figmaRight / HERO_ARTBOARD.width) * 100),
  scale: 1.55,
};

function getMenubarComputed() {
  const topPx = HERO_MENUBAR_BASE.figmaTop * HERO_MENUBAR_CORRECTION.top;
  const rightPx = HERO_MENUBAR_BASE.figmaRight * HERO_MENUBAR_CORRECTION.right;
  const scale = HERO_MENUBAR_BASE.scale * HERO_MENUBAR_CORRECTION.scale;
  const mobileScale = HERO_MENUBAR_BASE.mobileScale * HERO_MENUBAR_CORRECTION.scale;
  return {
    topPx,
    rightPx,
    anchorTop: `${artboardPxToTopPercent(topPx).toFixed(2)}%`,
    marginRight: `${artboardPxToRightPercent(rightPx).toFixed(2)}%`,
    scale: Math.round(scale * 1000) / 1000,
    mobileScale: Math.round(mobileScale * 1000) / 1000,
  };
}

const HERO_FIGMA_SCREEN = { paddingTop: 125, paddingRight: 141 };

const HERO_FIGMA_PANEL = { gapBelowMenubar: 20, insetBeyondPaddingRight: 30 };

const HERO_PANEL_WIDTH_ON_SCREEN = 0.191;

function getMenubarRenderedHeightPx() {
  const emPx = 0.52 * (HERO_ARTBOARD.width / 100);
  return emPx * HERO_MENUBAR_BASE.iconScale * getMenubarComputed().scale;
}

function getPanelBasePx() {
  const menubar = getMenubarComputed();
  const menubarHeight = (menubar.topPx - HERO_FIGMA_SCREEN.paddingTop) + getMenubarRenderedHeightPx();
  return {
    topPx: HERO_FIGMA_SCREEN.paddingTop + menubarHeight + HERO_FIGMA_PANEL.gapBelowMenubar,
    rightPx: HERO_FIGMA_SCREEN.paddingRight + HERO_FIGMA_PANEL.insetBeyondPaddingRight,
  };
}

/* SVG inner-screen geometry (panel width still % of inner screen) */
const HERO_SCREEN_GEOMETRY = {
  top: 124.92 / 3239,
  width: (5970.48 - 140.89) / 6111,
  height: (3239 - 124.92) / 3239,
  rightInset: (6111 - 5970.48) / 6111,
};

function artboardPxToTopPercent(px) {
  return (px / HERO_ARTBOARD.height) * 100;
}

function artboardPxToRightPercent(px) {
  return (px / HERO_ARTBOARD.width) * 100;
}

const HERO_PANEL_BASE = { popoverScale: 0.91, mobilePopoverScale: 1.01 };

/* Visual correction vs computed base (tune @ 1920 → 8.5%, 3.7%, scale 0.85) */
const HERO_PANEL_CORRECTION = (() => {
  const base = getPanelBasePx();
  return {
    top: 8.5 / artboardPxToTopPercent(base.topPx),
    right: 3.7 / artboardPxToRightPercent(base.rightPx),
    scale: 0.85 / HERO_PANEL_BASE.popoverScale,
  };
})();

/* Tablet-only correction (tune @ 1020 → top 9.5%, scale 1.35) */
const HERO_PANEL_TABLET_CORRECTION = (() => {
  const base = getPanelBasePx();
  return {
    top: 9.5 / artboardPxToTopPercent(base.topPx),
    scale: 1.35,
  };
})();

function getPanelComputed() {
  const base = getPanelBasePx();
  const topPx = base.topPx * HERO_PANEL_CORRECTION.top;
  const rightPx = base.rightPx * HERO_PANEL_CORRECTION.right;
  const scale = Math.round(HERO_PANEL_BASE.popoverScale * HERO_PANEL_CORRECTION.scale * 1000) / 1000;
  const mobileScale = Math.round(HERO_PANEL_BASE.mobilePopoverScale * HERO_PANEL_CORRECTION.scale * 1000) / 1000;
  return {
    topPx,
    rightPx,
    panelTop: `${artboardPxToTopPercent(topPx).toFixed(2)}%`,
    panelMarginRight: `${artboardPxToRightPercent(rightPx).toFixed(2)}%`,
    panelWidth: `${(HERO_PANEL_WIDTH_ON_SCREEN * HERO_SCREEN_GEOMETRY.width * 100).toFixed(2)}%`,
    scale,
    mobileScale,
  };
}

/* Mobile-only correction (tune @ 490 → top/right/scale; @ 444 → width 20%) */
const HERO_PANEL_MOBILE_CORRECTION = (() => {
  const panel = getPanelComputed();
  return {
    top: 9.15 / parseFloat(panel.panelTop),
    right: 6 / parseFloat(panel.panelMarginRight),
    width: 20 / parseFloat(panel.panelWidth),
    scale: 1.39 / panel.mobileScale,
  };
})();

function getMobilePanelComputed() {
  const base = getPanelBasePx();
  const panel = getPanelComputed();
  const topPx = base.topPx * HERO_PANEL_MOBILE_CORRECTION.top;
  return {
    panelTop: `${artboardPxToTopPercent(topPx).toFixed(2)}%`,
    panelMarginRight: `${(parseFloat(panel.panelMarginRight) * HERO_PANEL_MOBILE_CORRECTION.right).toFixed(2)}%`,
    panelWidth: `${(parseFloat(panel.panelWidth) * HERO_PANEL_MOBILE_CORRECTION.width).toFixed(2)}%`,
    scale: Math.round(panel.mobileScale * HERO_PANEL_MOBILE_CORRECTION.scale * 1000) / 1000,
  };
}

function getTabletPanelComputed() {
  const base = getPanelBasePx();
  const panel = getPanelComputed();
  const topPx = base.topPx * HERO_PANEL_TABLET_CORRECTION.top;
  return {
    panelTop: `${artboardPxToTopPercent(topPx).toFixed(2)}%`,
    panelMarginRight: panel.panelMarginRight,
    panelWidth: panel.panelWidth,
    scale: HERO_PANEL_TABLET_CORRECTION.scale,
  };
}

function getHudDefaultsFromGeometry() {
  const menubar = getMenubarComputed();
  const panel = getPanelComputed();
  const tabletPanel = getTabletPanelComputed();
  const mobilePanel = getMobilePanelComputed();
  return {
    '--hud-anchor-top': menubar.anchorTop,
    '--hud-margin-right': menubar.marginRight,
    '--menubar-scale': String(menubar.scale),
    '--mobile-hud-anchor-top': menubar.anchorTop,
    '--mobile-hud-margin-right': menubar.marginRight,
    '--mobile-menubar-scale': String(menubar.mobileScale),
    '--hud-panel-top': panel.panelTop,
    '--hud-panel-margin-right': panel.panelMarginRight,
    '--hud-panel-width': panel.panelWidth,
    '--popover-scale': String(panel.scale),
    '--tablet-hud-panel-top': tabletPanel.panelTop,
    '--tablet-hud-panel-margin-right': tabletPanel.panelMarginRight,
    '--tablet-hud-panel-width': tabletPanel.panelWidth,
    '--tablet-popover-scale': String(tabletPanel.scale),
    '--mobile-hud-panel-top': mobilePanel.panelTop,
    '--mobile-hud-panel-margin-right': mobilePanel.panelMarginRight,
    '--mobile-hud-panel-width': mobilePanel.panelWidth,
    '--mobile-popover-scale': String(mobilePanel.scale),
  };
}

const HERO_DESKTOP_ANCHOR = {
  width: 1920,
  fluidMax: 1.22,
  tabletTuneWidth: 1022,
  tabletFluidMax: 1.18,
  mockupY: 10,
  mockupScale: 1.15,
  tabletMockupScale: 1.2,
};

const HERO_LAYOUT_VARS = ['--mockup-x', '--mockup-y', '--tablet-mockup-x', '--tablet-mockup-stage-height'];

function readRootPx(name, fallback) {
  const raw = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  if (!raw) return fallback;
  if (raw.endsWith('rem')) {
    const rootFont = Number.parseFloat(getComputedStyle(document.documentElement).fontSize);
    const rem = Number.parseFloat(raw);
    return Number.isFinite(rem) && Number.isFinite(rootFont) ? rem * rootFont : fallback;
  }
  const value = Number.parseFloat(raw);
  return Number.isFinite(value) ? value : fallback;
}

function computeTabletStageHeight(width) {
  const headerPx = readRootPx('--header-height', 64);
  const tuneWidth = HERO_DESKTOP_ANCHOR.tabletTuneWidth;
  const baseWidth = getMockupBaseWidth(width, tuneWidth);
  const artboardHeight = baseWidth * (3239 / 6111);
  const scale = getMockupEffectiveScale(width, { tablet: true });
  const scaledHeight = artboardHeight * scale;
  const mockupY = readRootNumber('--tablet-mockup-y', 13);
  const mockupBottom = headerPx + mockupY + scaledHeight;
  const panelTop = readRootPercent('--tablet-hud-panel-top', 9.5);
  const panelScale = readRootNumber('--tablet-popover-scale', 1.35);
  const panelApproxHeight = scaledHeight * 0.36 * panelScale;
  const panelBottom = headerPx + mockupY + scaledHeight * panelTop + panelApproxHeight;

  return Math.ceil(Math.max(mockupBottom, panelBottom) + 12);
}

function getHeroFluidFactor(width, tuneWidth = HERO_DESKTOP_ANCHOR.width, fluidMax = HERO_DESKTOP_ANCHOR.fluidMax) {
  return Math.min(Math.max(1, tuneWidth / width), fluidMax);
}

function getMockupBaseWidth(width, tuneWidth = HERO_DESKTOP_ANCHOR.width) {
  const layoutWidth = width >= tuneWidth ? tuneWidth : width;
  return layoutWidth * MOCKUP_ARTBOARD_RATIO;
}

function readRootNumber(name, fallback) {
  const raw = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const value = Number.parseFloat(raw);
  return Number.isFinite(value) ? value : fallback;
}

function readRootPercent(name, fallbackPercent) {
  const raw = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  if (!raw) return fallbackPercent / 100;
  if (raw.endsWith('%')) {
    const value = Number.parseFloat(raw);
    return Number.isFinite(value) ? value / 100 : fallbackPercent / 100;
  }
  const value = Number.parseFloat(raw);
  return Number.isFinite(value) ? value / 100 : fallbackPercent / 100;
}

function getMockupEffectiveScale(width, { tablet = false } = {}) {
  const tuneWidth = tablet ? HERO_DESKTOP_ANCHOR.tabletTuneWidth : HERO_DESKTOP_ANCHOR.width;
  const fluidMax = tablet ? HERO_DESKTOP_ANCHOR.tabletFluidMax : HERO_DESKTOP_ANCHOR.fluidMax;
  const scale = tablet
    ? readRootNumber('--tablet-mockup-scale', HERO_DESKTOP_ANCHOR.tabletMockupScale)
    : readRootNumber('--mockup-scale', HERO_DESKTOP_ANCHOR.mockupScale);
  if (width >= tuneWidth) return scale;
  return scale * getHeroFluidFactor(width, tuneWidth, fluidMax);
}

function computeMockupX(width, { tablet = false } = {}) {
  const tuneWidth = tablet ? HERO_DESKTOP_ANCHOR.tabletTuneWidth : HERO_DESKTOP_ANCHOR.width;
  const scaledWidth = getMockupBaseWidth(width, tuneWidth) * getMockupEffectiveScale(width, { tablet });
  const marginRight = tablet ? MOCKUP_SCREEN_MARGIN_RIGHT_TABLET : MOCKUP_SCREEN_MARGIN_RIGHT;
  const baseX = (width / 2) - marginRight - (scaledWidth / 2);
  return tablet ? baseX + HERO_TABLET_MOCKUP_X_CORRECTION : baseX;
}

function getMobileStageWidth(viewportWidth) {
  return viewportWidth;
}

function computeMobileMockupOffsetX(viewportWidth) {
  const stageWidth = getMobileStageWidth(viewportWidth);
  const scale = readRootNumber('--mobile-mockup-scale', HERO_MOBILE_MOCKUP_TUNE_SCALE);
  const widthPct = readRootNumber('--mobile-mockup-width', 251) / 100;
  const scaledWidth = stageWidth * widthPct * scale;
  const scaleNudge = (HERO_MOBILE_MOCKUP_TUNE_SCALE - scale) * scaledWidth * 0.5;
  return Math.round((HERO_MOBILE_MOCKUP_X_CORRECTION + scaleNudge) * 100) / 100;
}

function applyHudGeometryDefaults() {
  const defaults = getHudDefaultsFromGeometry();
  const root = document.documentElement;
  Object.entries(defaults).forEach(([name, value]) => {
    if (!root.style.getPropertyValue(name)) {
      root.style.setProperty(name, value);
    }
  });
}

function clearHeroDesktopLayout() {
  HERO_LAYOUT_VARS.forEach((name) => document.documentElement.style.removeProperty(name));
}

function applyHeroDesktopLayout() {
  const width = window.innerWidth;
  const root = document.documentElement;
  const isTablet = width > HERO_MOBILE_MAX && width <= HERO_TABLET_MAX;
  const marginRight = isTablet ? MOCKUP_SCREEN_MARGIN_RIGHT_TABLET : MOCKUP_SCREEN_MARGIN_RIGHT;
  root.style.setProperty('--mockup-screen-margin-right', `${marginRight}px`);

  if (width <= HERO_MOBILE_MAX) {
    clearHeroDesktopLayout();
    root.style.setProperty('--mobile-mockup-offset-x', `${computeMobileMockupOffsetX(width)}px`);
    return;
  }

  root.style.removeProperty('--mobile-mockup-offset-x');

  const mockupX = Math.round(computeMockupX(width, { tablet: isTablet }) * 100) / 100;

  if (width <= HERO_TABLET_MAX) {
    root.style.setProperty('--tablet-mockup-x', `${mockupX}px`);
    root.style.setProperty('--tablet-mockup-y', `${readRootNumber('--tablet-mockup-y', 13)}px`);
    root.style.setProperty('--tablet-mockup-stage-height', `${computeTabletStageHeight(width)}px`);
    root.style.removeProperty('--mockup-x');
    root.style.removeProperty('--mockup-y');
    return;
  }

  root.style.setProperty('--mockup-x', `${mockupX}px`);
  root.style.setProperty('--mockup-y', `${HERO_DESKTOP_ANCHOR.mockupY}px`);
  root.style.removeProperty('--tablet-mockup-x');
  root.style.removeProperty('--tablet-mockup-y');
  root.style.removeProperty('--tablet-mockup-stage-height');
}

applyHudGeometryDefaults();
applyHeroDesktopLayout();

window.addEventListener('resize', applyHeroDesktopLayout);
window.visualViewport?.addEventListener('resize', applyHeroDesktopLayout);

const themeMedia = window.matchMedia('(prefers-color-scheme: dark)');
const themeToggle = document.querySelector('#theme-toggle');
const themeNames = { system: 'System', light: 'Light', dark: 'Dark' };

function applyThemePreference(preference, persist = true) {
  const resolvedTheme = preference === 'system'
    ? (themeMedia.matches ? 'dark' : 'light')
    : preference;

  root.dataset.theme = resolvedTheme;
  root.dataset.themePreference = preference;
  themeToggle.dataset.themeValue = preference;
  themeToggle.title = `${themeNames[preference]} theme`;
  updateThemeToggleLabel();

  if (persist) {
    try {
      localStorage.setItem('codexbar-theme', preference);
    } catch (_) {}
  }
}

function updateThemeToggleLabel() {
  const nextTheme = root.dataset.theme === 'dark' ? 'light' : 'dark';
  const label = message(nextTheme === 'dark' ? 'theme.toDark' : 'theme.toLight');
  themeToggle.setAttribute('aria-label', label);
  themeToggle.title = label;
}

themeToggle.addEventListener('click', () => {
  const nextPreference = root.dataset.theme === 'dark' ? 'light' : 'dark';
  applyThemePreference(nextPreference);
});

themeMedia.addEventListener('change', () => {
  if (root.dataset.themePreference === 'system') applyThemePreference('system', false);
});

applyThemePreference(root.dataset.themePreference || 'system', false);

const languageShortNames = {
  en: 'EN',
  'zh-CN': '简',
  'zh-TW': '繁',
  'ja-JP': 'JA',
  es: 'ES',
  'pt-BR': 'PT',
  ko: 'KO',
  de: 'DE',
  fr: 'FR',
  ar: 'AR',
  it: 'IT',
  vi: 'VI',
  nl: 'NL',
  tr: 'TR',
  uk: 'UK',
  id: 'ID',
  pl: 'PL',
  fa: 'FA',
  th: 'TH',
  ca: 'CA',
  sv: 'SV',
};
const languages = localeCatalog.map((language) => ({
  ...language,
  id: language.code,
  short: languageShortNames[language.code] || language.code.slice(0, 2).toUpperCase(),
  label: language.name,
}));
const supportedLanguages = new Set(languages.map((language) => language.id));
const rtlLanguages = new Set(localeCatalog.filter((language) => language.direction === 'rtl').map((language) => language.code));
const localeAliases = {
  'zh-cn': 'zh-CN',
  'zh-hans': 'zh-CN',
  'zh-hant': 'zh-TW',
  'zh-hk': 'zh-TW',
  'zh-tw': 'zh-TW',
  ja: 'ja-JP',
  pt: 'pt-BR',
  'pt-br': 'pt-BR',
};
const languageStorageKey = 'codexbar-language';
const languagePicker = document.querySelector('#language-picker');
const languageTrigger = document.querySelector('#language-picker-trigger');
const languageMenu = document.querySelector('#language-picker-menu');
const languageList = document.querySelector('#language-picker-list');
const languageShort = document.querySelector('[data-lang-short]');

function normalizeLocale(value) {
  if (!value) return null;
  const lower = value.toLowerCase();
  if (localeAliases[lower]) return localeAliases[lower];
  return languages.find((language) => language.id.toLowerCase() === lower || lower.startsWith(`${language.id.toLowerCase()}-`))?.id || null;
}

function selectedLocale() {
  try {
    const queryLocale = normalizeLocale(new URLSearchParams(location.search).get('lang'));
    if (queryLocale) return queryLocale;
    const storedLocale = normalizeLocale(localStorage.getItem(languageStorageKey));
    if (storedLocale) return storedLocale;
  } catch (_) {}

  for (const language of navigator.languages || [navigator.language]) {
    const locale = normalizeLocale(language);
    if (locale) return locale;
  }
  return 'en';
}

let activeLanguage = selectedLocale();
if (!supportedLanguages.has(activeLanguage)) activeLanguage = 'en';

function message(key) {
  return activeMessages[key] || localeMessages.en[key] || key;
}

function applyAttributeMessages(dataAttribute, targetAttribute) {
  document.querySelectorAll(`[${dataAttribute}]`).forEach((element) => {
    element.setAttribute(targetAttribute, message(element.getAttribute(dataAttribute)));
  });
}

function richToken(name) {
  const codeTokens = {
    cask: 'brew install --cask steipete/tap/codexbar',
    codexbar: 'codexbar',
    linuxCommand: 'brew install steipete/tap/codexbar',
    upgrade: 'brew upgrade',
  };
  if (codeTokens[name]) {
    const code = document.createElement('code');
    code.className = 'inline-code';
    code.textContent = codeTokens[name];
    return code;
  }
  if (name === 'releases') {
    const link = document.createElement('a');
    link.className = 'text-link';
    link.href = 'https://github.com/steipete/CodexBar/releases';
    link.textContent = 'GitHub Releases';
    return link;
  }
  if (name === 'issue') {
    const link = document.createElement('a');
    link.className = 'text-link';
    link.href = 'https://github.com/steipete/CodexBar/issues/12';
    link.textContent = 'issue #12';
    return link;
  }
  if (name === 'mobileBreak') {
    return document.createElement('br');
  }
  if (name === 'break') {
    const wrapper = document.createDocumentFragment();
    const space = document.createElement('span');
    space.className = 'inline sm:hidden';
    space.textContent = ' ';
    const br = document.createElement('br');
    br.className = 'hidden sm:block';
    wrapper.append(space, br);
    return wrapper;
  }
  return document.createTextNode(`{${name}}`);
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

function applyLanguageMessages() {
  activeMessages = { ...localeMessages.en, ...(localeMessages[activeLanguage] || {}) };
  root.lang = activeLanguage;
  root.dir = rtlLanguages.has(activeLanguage) ? 'rtl' : 'ltr';
  root.dataset.locale = activeLanguage;
  document.title = message('meta.title');
  document.querySelector('meta[name="description"]')?.setAttribute('content', message('meta.description'));
  document.querySelector('meta[property="og:description"]')?.setAttribute('content', message('meta.ogDescription'));
  document.querySelectorAll('[data-i18n]').forEach((element) => {
    element.textContent = message(element.dataset.i18n);
  });
  document.querySelectorAll('[data-i18n-rich]').forEach((element) => {
    renderRichMessage(element, message(element.dataset.i18nRich));
  });
  applyAttributeMessages('data-i18n-aria-label', 'aria-label');
  applyAttributeMessages('data-i18n-title', 'title');
  applyAttributeMessages('data-i18n-alt', 'alt');
  updateThemeToggleLabel();
}

function renderLanguageMenu() {
  languageList.replaceChildren();
  languages.forEach((language) => {
    const option = document.createElement('button');
    option.type = 'button';
    option.className = 'language-option button-press';
    option.role = 'option';
    option.dataset.lang = language.id;
    option.setAttribute('aria-selected', String(language.id === activeLanguage));
    option.tabIndex = language.id === activeLanguage ? 0 : -1;
    option.innerHTML = `
      <svg viewBox="0 0 18 18" fill="none" aria-hidden="true">
        <path d="M4.5 9.25 7.5 12.25 13.5 6.25" stroke="currentColor" stroke-width="1.75" stroke-linecap="round" stroke-linejoin="round" />
      </svg>
      <span>${language.label}</span>
    `;
    option.addEventListener('click', () => selectLanguage(language.id));
    languageList.append(option);
  });
}

function updateLanguageUi() {
  const current = languages.find((language) => language.id === activeLanguage) || languages[0];
  languageShort.textContent = current.short;
  root.dataset.language = current.id;
  applyLanguageMessages();
  languageList.querySelectorAll('[role="option"]').forEach((option) => {
    const selected = option.dataset.lang === activeLanguage;
    option.setAttribute('aria-selected', String(selected));
    option.tabIndex = selected ? 0 : -1;
  });
}

function setLanguageMenuOpen(open, { focusOption = false, restoreFocus = false } = {}) {
  languageMenu.hidden = !open;
  languageTrigger.setAttribute('aria-expanded', String(open));
  if (open && focusOption) {
    languageList.querySelector('[aria-selected="true"]')?.focus();
  } else if (!open && restoreFocus) {
    languageTrigger.focus();
  }
}

function selectLanguage(languageId) {
  activeLanguage = languageId;
  try {
    localStorage.setItem(languageStorageKey, languageId);
    const url = new URL(location.href);
    url.searchParams.set('lang', languageId);
    history.replaceState(null, '', url);
  } catch (_) {}
  updateLanguageUi();
  setLanguageMenuOpen(false, { restoreFocus: true });
}

renderLanguageMenu();
updateLanguageUi();

languageTrigger.addEventListener('click', () => {
  setLanguageMenuOpen(languageMenu.hidden, { focusOption: languageMenu.hidden });
});

languageTrigger.addEventListener('keydown', (event) => {
  if (event.key !== 'ArrowDown' && event.key !== 'ArrowUp') return;
  event.preventDefault();
  setLanguageMenuOpen(true, { focusOption: true });
});

languageList.addEventListener('keydown', (event) => {
  const options = [...languageList.querySelectorAll('[role="option"]')];
  const currentIndex = Math.max(0, options.indexOf(document.activeElement));
  let nextIndex;
  if (event.key === 'ArrowDown') nextIndex = (currentIndex + 1) % options.length;
  if (event.key === 'ArrowUp') nextIndex = (currentIndex - 1 + options.length) % options.length;
  if (event.key === 'Home') nextIndex = 0;
  if (event.key === 'End') nextIndex = options.length - 1;
  if (nextIndex === undefined) return;
  event.preventDefault();
  options[nextIndex]?.focus();
});

document.addEventListener('click', (event) => {
  if (!languagePicker.contains(event.target)) setLanguageMenuOpen(false);
});

document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && !languageMenu.hidden) {
    event.preventDefault();
    setLanguageMenuOpen(false, { restoreFocus: true });
  }
});

const providerSection = document.querySelector('[data-provider-section]');
const providerCards = providerSection.querySelectorAll('.provider-card:not([hidden])');
providerCards.forEach((card, index) => {
  card.classList.add('provider-reveal');
  card.style.setProperty('--reveal-delay', `${80 + Math.min(index, 12) * 24}ms`);
});

const revealSection = (section) => section.classList.add('is-revealed');

if ('IntersectionObserver' in window) {
  const revealObserver = new IntersectionObserver((entries, observer) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      revealSection(entry.target);
      observer.unobserve(entry.target);
    });
  }, { threshold: 0.01, rootMargin: '0px 0px -8% 0px' });

  [providerSection, ...document.querySelectorAll('[data-scroll-section]')].forEach((section) => {
    revealObserver.observe(section);
  });
} else {
  revealSection(providerSection);
  document.querySelectorAll('[data-scroll-section]').forEach(revealSection);
}

document.querySelectorAll('.mac-widget-gallery-wrap').forEach((wrap) => {
  const gallery = wrap.querySelector('.mac-widget-gallery');
  if (!gallery) return;

  const syncScrollFade = () => {
    const overflows = gallery.scrollHeight > gallery.clientHeight + 1;
    const atBottom = gallery.scrollTop + gallery.clientHeight >= gallery.scrollHeight - 2;
    wrap.classList.toggle('has-scroll-fade', overflows && !atBottom);
  };

  gallery.addEventListener('scroll', syncScrollFade, { passive: true });
  window.addEventListener('resize', syncScrollFade);
  if ('ResizeObserver' in window) {
    new ResizeObserver(syncScrollFade).observe(gallery);
  }
  syncScrollFade();
});

const mockupStage = document.querySelector('#mockup-stage');
const menubarItems = mockupStage.querySelectorAll('.system-menubar > *');
const heroRootStyles = getComputedStyle(document.documentElement);
const readHeroMs = (name) => Number.parseFloat(heroRootStyles.getPropertyValue(name)) || 0;
const menubarStartDelay = readHeroMs('--hero-menubar-start');
const menubarWaveGap = readHeroMs('--hero-menubar-wave');
const reducedHeroMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
const lastMenubarItemDelay = Math.max(0, menubarItems.length - 1) * menubarWaveGap;
const markStartDelay = menubarStartDelay + lastMenubarItemDelay + readHeroMs('--hero-mark-after-menubar');
const popoverStartDelay = markStartDelay + readHeroMs('--hero-popover-after-mark');

menubarItems.forEach((item, index) => {
  item.style.setProperty('--menubar-enter-delay', `${reducedHeroMotion ? 0 : index * menubarWaveGap}ms`);
});

const animatePopoverDetails = () => {
  mockupStage.querySelectorAll('.usage-meter').forEach((meter, index) => {
    meter.style.setProperty('--meter-delay', `${reducedHeroMotion ? 0 : 70 + index * 70}ms`);
  });
  mockupStage.querySelectorAll('.usage-chart i').forEach((bar, index) => {
    bar.style.setProperty('--bar-delay', `${reducedHeroMotion ? 0 : 120 + index * 6}ms`);
  });
  mockupStage.classList.add('is-animated');
};

if (reducedHeroMotion) {
  mockupStage.classList.add('is-menubar-entered', 'is-mark-animated');
  animatePopoverDetails();
} else {
  window.setTimeout(() => mockupStage.classList.add('is-menubar-entered'), menubarStartDelay);
  window.setTimeout(() => mockupStage.classList.add('is-mark-animated'), markStartDelay);
  window.setTimeout(animatePopoverDetails, popoverStartDelay);
}

const brewCopyButton = document.querySelector('#brew-copy');
const brewCopyLabel = brewCopyButton?.querySelector('[data-brew-label]');
const brewCopyIcon = brewCopyButton?.querySelector('[data-brew-icon]');
const brewCopyStatus = brewCopyButton?.querySelector('[data-brew-status]');
let brewCopyResetTimer;

async function copyBrewCommand() {
  const command = brewCopyLabel?.textContent?.trim();
  if (!command || !navigator.clipboard?.writeText) return;

  try {
    await navigator.clipboard.writeText(command);
  } catch (_) {
    return;
  }

  window.clearTimeout(brewCopyResetTimer);
  brewCopyIcon.dataset.copied = 'true';
  brewCopyStatus.textContent = message('clipboard.copied');
  brewCopyButton.setAttribute('aria-label', message('clipboard.copied'));
  brewCopyResetTimer = window.setTimeout(() => {
    delete brewCopyIcon.dataset.copied;
    brewCopyStatus.textContent = '';
    brewCopyButton.setAttribute('aria-label', message('clipboard.copyBrew'));
  }, 1500);
}

brewCopyButton?.addEventListener('click', copyBrewCommand);
