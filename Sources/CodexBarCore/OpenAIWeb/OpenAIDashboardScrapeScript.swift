#if os(macOS)
let openAIDashboardScrapeScript = """

    (() => {
      const textOf = el => {
        const raw = el && (el.innerText || el.textContent) ? String(el.innerText || el.textContent) : '';
        return raw.trim();
      };
      const parseHexColor = (color) => {
        if (!color) return null;
        const c = String(color).trim().toLowerCase();
        if (c.startsWith('#')) {
          if (c.length === 4) {
            return '#' + c[1] + c[1] + c[2] + c[2] + c[3] + c[3];
          }
          if (c.length === 7) return c;
          return c;
        }
        const m = c.match(/^rgba?\\(([^)]+)\\)$/);
        if (m) {
          const parts = m[1].split(',').map(x => parseFloat(x.trim())).filter(x => Number.isFinite(x));
          if (parts.length >= 3) {
            const r = Math.max(0, Math.min(255, Math.round(parts[0])));
            const g = Math.max(0, Math.min(255, Math.round(parts[1])));
            const b = Math.max(0, Math.min(255, Math.round(parts[2])));
            const toHex = n => n.toString(16).padStart(2, '0');
            return '#' + toHex(r) + toHex(g) + toHex(b);
          }
        }
        return c;
      };
      const reactPropsOf = (el) => {
        if (!el) return null;
        try {
          const keys = Object.keys(el);
          const propsKey = keys.find(k => k.startsWith('__reactProps$'));
          if (propsKey) return el[propsKey] || null;
          const fiberKey = keys.find(k => k.startsWith('__reactFiber$'));
          if (fiberKey) {
            const fiber = el[fiberKey];
            return (fiber && (fiber.memoizedProps || fiber.pendingProps)) || null;
          }
        } catch {}
        return null;
      };
      const reactFiberOf = (el) => {
        if (!el) return null;
        try {
          const keys = Object.keys(el);
          const fiberKey = keys.find(k => k.startsWith('__reactFiber$'));
          return fiberKey ? (el[fiberKey] || null) : null;
        } catch {
          return null;
        }
      };
      const nestedBarMetaOf = (root) => {
        if (!root || typeof root !== 'object') return null;
        const queue = [root];
        const seen = typeof WeakSet !== 'undefined' ? new WeakSet() : null;
        let steps = 0;
        while (queue.length && steps < 250) {
          const cur = queue.shift();
          steps++;
          if (!cur || typeof cur !== 'object') continue;
          if (seen) {
            if (seen.has(cur)) continue;
            seen.add(cur);
          }
          if (cur.payload && (cur.dataKey || cur.name || cur.value !== undefined)) return cur;
          const values = Array.isArray(cur) ? cur : Object.values(cur);
          for (const v of values) {
            if (v && typeof v === 'object') queue.push(v);
          }
        }
        return null;
      };
      const barMetaFromElement = (el) => {
        const direct = reactPropsOf(el);
        if (direct && direct.payload && (direct.dataKey || direct.name || direct.value !== undefined)) return direct;

        const fiber = reactFiberOf(el);
        if (fiber) {
          let cur = fiber;
          for (let i = 0; i < 10 && cur; i++) {
            const props = (cur.memoizedProps || cur.pendingProps) || null;
            if (props && props.payload && (props.dataKey || props.name || props.value !== undefined)) return props;
            const nested = props ? nestedBarMetaOf(props) : null;
            if (nested) return nested;
            cur = cur.return || null;
          }
        }

        if (direct) {
          const nested = nestedBarMetaOf(direct);
          if (nested) return nested;
        }
        return null;
      };
      const normalizeHref = (raw) => {
        if (!raw) return null;
        const href = String(raw).trim();
        if (!href) return null;
        if (href.startsWith('http://') || href.startsWith('https://')) return href;
        if (href.startsWith('//')) return window.location.protocol + href;
        if (href.startsWith('/')) return window.location.origin + href;
        return window.location.origin + '/' + href;
      };
      const isLikelyCreditsURL = (raw) => {
        if (!raw) return false;
        try {
          const url = new URL(raw, window.location.origin);
          if (!url.host || !url.host.includes('chatgpt.com')) return false;
          const path = url.pathname.toLowerCase();
          return (
            path.includes('settings') ||
            path.includes('usage') ||
            path.includes('billing') ||
            path.includes('credits')
          );
        } catch {
          return false;
        }
      };
      const purchaseTextMatches = (text) => {
        const lower = String(text || '').trim().toLowerCase();
        if (!lower) return false;
        if (lower.includes('add more')) return true;
        if (!lower.includes('credit')) return false;
        return (
          lower.includes('buy') ||
          lower.includes('add') ||
          lower.includes('purchase') ||
          lower.includes('top up') ||
          lower.includes('top-up')
        );
      };
      const elementLabel = (el) => {
        if (!el) return '';
        return (
          textOf(el) ||
          el.getAttribute('aria-label') ||
          el.getAttribute('title') ||
          ''
        );
      };
      const urlFromProps = (props) => {
        if (!props || typeof props !== 'object') return null;
        const candidates = [
          props.href,
          props.to,
          props.url,
          props.link,
          props.destination,
          props.navigateTo
        ];
        for (const candidate of candidates) {
          if (typeof candidate === 'string' && candidate.trim()) {
            return normalizeHref(candidate);
          }
        }
        return null;
      };
      const purchaseURLFromElement = (el) => {
        if (!el) return null;
        const isAnchor = el.tagName && el.tagName.toLowerCase() === 'a';
        const anchor = isAnchor ? el : (el.closest ? el.closest('a') : null);
        const anchorHref = anchor ? anchor.getAttribute('href') : null;
        const dataHref = el.getAttribute
          ? (el.getAttribute('data-href') ||
            el.getAttribute('data-url') ||
            el.getAttribute('data-link') ||
            el.getAttribute('data-destination'))
          : null;
        const propHref = urlFromProps(reactPropsOf(el)) || urlFromProps(reactPropsOf(anchor));
        const normalized = normalizeHref(anchorHref || dataHref || propHref);
        return normalized && isLikelyCreditsURL(normalized) ? normalized : null;
      };
      const pickLikelyPurchaseButton = (buttons) => {
        if (!buttons || buttons.length === 0) return null;
        const labeled = buttons.find(btn => {
          const label = elementLabel(btn);
          if (purchaseTextMatches(label)) return true;
          const aria = String(btn.getAttribute('aria-label') || '').toLowerCase();
          return aria.includes('credit') || aria.includes('buy') || aria.includes('add');
        });
        return labeled || buttons[0];
      };
      const findCreditsPurchaseButton = () => {
        const nodes = Array.from(document.querySelectorAll('h1,h2,h3,div,span,p'));
        const labelMatch = nodes.find(node => {
          const lower = textOf(node).toLowerCase();
          return lower === 'credits remaining' || (lower.includes('credits') && lower.includes('remaining'));
        });
        if (!labelMatch) return null;
        let cur = labelMatch;
        for (let i = 0; i < 6 && cur; i++) {
          const buttons = Array.from(cur.querySelectorAll('button, a'));
          const picked = pickLikelyPurchaseButton(buttons);
          if (picked) return picked;
          cur = cur.parentElement;
        }
        return null;
      };
      const dayKeyFromPayload = (payload) => {
        if (!payload || typeof payload !== 'object') return null;
        const localDayKeyForDate = (date) => {
          const year = date.getFullYear();
          const month = String(date.getMonth() + 1).padStart(2, '0');
          const day = String(date.getDate()).padStart(2, '0');
          return `${year}-${month}-${day}`;
        };
        const keys = ['day', 'date', 'name', 'label', 'x', 'time', 'timestamp'];
        for (const k of keys) {
          const v = payload[k];
          if (typeof v === 'string') {
            const s = v.trim();
            if (/^\\d{4}-\\d{2}-\\d{2}$/.test(s)) return s;
            const iso = s.match(/^(\\d{4}-\\d{2}-\\d{2})/);
            if (iso) return iso[1];
          }
          if (typeof v === 'number' && Number.isFinite(v) && (k === 'timestamp' || k === 'time' || k === 'x')) {
            try {
              const d = new Date(v);
              if (!isNaN(d.getTime())) return localDayKeyForDate(d);
            } catch {}
          }
        }
        return null;
      };
      const isSkillUsageServiceKey = (raw) => {
        const key = raw === null || raw === undefined ? '' : String(raw).trim().toLowerCase();
        return key.startsWith('skillusage:');
      };
      const displayNameForUsageServiceKey = (raw) => {
        const key = raw === null || raw === undefined ? '' : String(raw).trim();
        if (!key) return key;
        if (isSkillUsageServiceKey(key)) return null;
        if (key.toUpperCase() === key && key.length <= 6) return key;
        const lower = key.toLowerCase();
        if (lower === 'cli') return 'CLI';
        if (lower.includes('github') && lower.includes('review')) return 'GitHub Code Review';
        const words = lower.replace(/[_-]+/g, ' ').split(' ').filter(Boolean);
        return words.map(w => w.length <= 2 ? w.toUpperCase() : w.charAt(0).toUpperCase() + w.slice(1)).join(' ');
      };
      const isLikelyCodexUsageService = (raw) => {
        const service = raw === null || raw === undefined ? '' : String(raw).trim().toLowerCase();
        return (
          service === 'cli' ||
          service === 'desktop' ||
          service === 'desktop app' ||
          service === 'vscode' ||
          service === 'vs code' ||
          service === 'unknown' ||
          (service.includes('github') && service.includes('review'))
        );
      };
      const usageChartRootForPath = (path) => {
        if (!path || !path.closest) return null;
        return (
          path.closest('.recharts-wrapper') ||
          path.closest('svg.recharts-surface') ||
          path.closest('section') ||
          path.parentElement ||
          null
        );
      };
      const uniqueUsageChartRoots = (paths) => {
        const roots = [];
        for (const path of paths) {
          const root = usageChartRootForPath(path);
          if (root && !roots.includes(root)) roots.push(root);
        }
        return roots;
      };
      const usageBreakdownTitleScore = (title) => {
        const lower = String(title || '').trim().toLowerCase().replace(/\\s+/g, ' ');
        if (!lower) return 0;
        if (lower === 'usage breakdown') return 1000000;
        if (lower.includes('usage breakdown')) return 900000;
        if (lower === 'personal usage') return 800000;
        if (lower.includes('threads') ||
          lower.includes('turns') ||
          lower.includes('client') ||
          lower.includes('skill') ||
          lower.includes('invocation')) return -1000000;
        return 0;
      };
      const titleLikeElements = (scope) => {
        try {
          return Array.from(scope.querySelectorAll('h1,h2,h3,[role=\"heading\"],div,span,p'))
            .filter(el => {
              const title = textOf(el);
              const lower = title.toLowerCase();
              const tag = el.tagName ? el.tagName.toLowerCase() : '';
              const isHeading = tag === 'h1' ||
                tag === 'h2' ||
                tag === 'h3' ||
                String(el.getAttribute('role') || '').toLowerCase() === 'heading';
              return title.length > 0 &&
                title.length <= 80 &&
                (
                  isHeading ||
                  usageBreakdownTitleScore(title) !== 0 ||
                  lower.includes('usage breakdown') ||
                  lower.includes('threads') ||
                  lower.includes('turns') ||
                  lower.includes('client') ||
                  lower.includes('skill') ||
                  lower.includes('invocation')
                );
            });
        } catch {
          return [];
        }
      };
      const titleNodePrecedesRoot = (titleNode, root) => {
        if (!titleNode || titleNode === root || root.contains(titleNode) || titleNode.contains(root)) return false;
        const relation = titleNode.compareDocumentPosition(root);
        return Boolean(relation & Node.DOCUMENT_POSITION_FOLLOWING);
      };
      const nearestScoredChartTitleInScope = (scope, root) => {
        let best = null;
        for (const titleNode of titleLikeElements(scope)) {
          if (!titleNodePrecedesRoot(titleNode, root)) continue;
          const title = textOf(titleNode);
          const score = usageBreakdownTitleScore(title);
          if (score === 0) continue;
          if (!best || score >= best.score) best = { title, score };
        }
        return best ? best.title : '';
      };
      const chartTitleBoundaryForRoot = (root) => {
        if (!root) return null;
        try {
          return root.closest('section,[role=\"region\"],article') || root.parentElement || null;
        } catch {
          return root.parentElement || null;
        }
      };
      const nearestTitleTextInScope = (scope, root) => {
        if (!scope) return '';
        let nearest = null;
        for (const titleNode of titleLikeElements(scope)) {
          if (titleNodePrecedesRoot(titleNode, root)) nearest = titleNode;
        }
        return textOf(nearest);
      };
      const nearestChartTitleTextForRoot = (root) => {
        if (!root) return '';
        try {
          const boundary = chartTitleBoundaryForRoot(root) || root.parentElement || null;
          let ancestor = root.parentElement || null;
          for (let i = 0; i < 8 && ancestor; i++) {
            const scoredTitle = nearestScoredChartTitleInScope(ancestor, root);
            if (scoredTitle) return scoredTitle;
            if (ancestor === boundary) break;
            ancestor = ancestor.parentElement || null;
          }

          return nearestTitleTextInScope(boundary, root);
        } catch {
          return '';
        }
      };
      const legendMapForUsageChartRoot = (root) => {
        const legendMap = {};
        const scopes = [
          root,
          root && root.parentElement,
          root && root.closest ? root.closest('section') : null
        ].filter(Boolean);
        for (const scope of scopes) {
          try {
            const legendItems = Array.from(scope.querySelectorAll('div[title]'));
            for (const item of legendItems) {
              const title = item.getAttribute('title') ? String(item.getAttribute('title')).trim() : '';
              const square = item.querySelector('div[style*=\"background-color\"]');
              const color = (square && square.style && square.style.backgroundColor)
                ? square.style.backgroundColor
                : null;
              const hex = parseHexColor(color);
              if (title && hex) legendMap[hex] = title;
            }
          } catch {}
          if (Object.keys(legendMap).length > 0) break;
        }
        return legendMap;
      };
      const parseUsageBreakdownFromChartPaths = (paths, legendMap) => {
        const totalsByDay = {}; // day -> service -> value
        const addValue = (day, service, value) => {
          if (!day || !service || isSkillUsageServiceKey(service)) return false;
          if (typeof value !== 'number' || !Number.isFinite(value) || value <= 0) return false;
          if (!totalsByDay[day]) totalsByDay[day] = {};
          totalsByDay[day][service] = (totalsByDay[day][service] || 0) + value;
          return true;
        };
        let pointCount = 0;
        for (const path of paths) {
          const meta = barMetaFromElement(path) || barMetaFromElement(path.parentElement) || null;
          if (!meta) continue;

          const payload = meta.payload || null;
          const day = dayKeyFromPayload(payload);
          if (!day) continue;

          const valuesObj = (payload && payload.values && typeof payload.values === 'object') ? payload.values : null;
          if (valuesObj) {
            for (const [k, v] of Object.entries(valuesObj)) {
              const service = displayNameForUsageServiceKey(k);
              if (addValue(day, service, v)) pointCount++;
            }
            continue;
          }

          let value = null;
          if (typeof meta.value === 'number' && Number.isFinite(meta.value)) value = meta.value;
          if (value === null && typeof meta.value === 'string') {
            const v = parseFloat(meta.value.replace(/,/g, ''));
            if (Number.isFinite(v)) value = v;
          }
          if (value === null) continue;

          const fill = parseHexColor(meta.fill || path.getAttribute('fill'));
          const service =
            (fill && legendMap[fill]) ||
            (typeof meta.name === 'string' && meta.name) ||
            null;
          if (addValue(day, service, value)) pointCount++;
        }

        const dayKeys = Object.keys(totalsByDay)
          .filter(day => Object.keys(totalsByDay[day] || {}).length > 0)
          .sort((a, b) => b.localeCompare(a))
          .slice(0, 30);
        const breakdown = dayKeys.map(day => {
          const servicesMap = totalsByDay[day] || {};
          const services = Object.keys(servicesMap).map(service => ({
            service,
            creditsUsed: servicesMap[service]
          })).sort((a, b) => {
            if (a.creditsUsed === b.creditsUsed) return a.service.localeCompare(b.service);
            return b.creditsUsed - a.creditsUsed;
          });
          const totalCreditsUsed = services.reduce((sum, s) => sum + (Number(s.creditsUsed) || 0), 0);
          return { day, services, totalCreditsUsed };
        });
        const services = Array.from(new Set(breakdown.flatMap(day => day.services.map(service => service.service))));
        const totalCreditsUsed = breakdown.reduce((sum, day) => sum + (Number(day.totalCreditsUsed) || 0), 0);
        const likelyCodexServiceCount = services.filter(isLikelyCodexUsageService).length;
        return {
          breakdown,
          pointCount,
          services,
          totalCreditsUsed,
          likelyCodexServiceCount,
          score: likelyCodexServiceCount * 1000 + services.length * 100 + pointCount + totalCreditsUsed / 1000
        };
      };
      const usageBreakdownJSON = (() => {
        try {
          if (window.__codexbarUsageBreakdownJSON) return window.__codexbarUsageBreakdownJSON;

          const paths = Array.from(document.querySelectorAll('g.recharts-bar-rectangle path.recharts-rectangle'));
          let debug = {
            pathCount: paths.length,
            chartCount: 0,
            eligibleCandidateCount: 0,
            selectedCandidateTitle: null,
            candidateSummaries: [],
            sampleReactKeys: null,
            sampleMetaKeys: null,
            samplePayloadKeys: null,
            sampleValuesKeys: null,
            sampleDayKey: null
          };
          try {
            const sample = paths[0] || null;
            if (sample) {
              const names = Object.getOwnPropertyNames(sample);
              debug.sampleReactKeys = names.filter(k => k.includes('react')).slice(0, 10);
              const metaSample = barMetaFromElement(sample) || barMetaFromElement(sample.parentElement) || null;
              if (metaSample) {
                debug.sampleMetaKeys = Object.keys(metaSample).slice(0, 12);
                const payload = metaSample.payload || null;
                if (payload && typeof payload === 'object') {
                  debug.samplePayloadKeys = Object.keys(payload).slice(0, 12);
                  debug.sampleDayKey = dayKeyFromPayload(payload);
                  const values = payload.values || null;
                  if (values && typeof values === 'object') {
                    debug.sampleValuesKeys = Object.keys(values).slice(0, 12);
                  }
                }
              }
            }
          } catch {}

          const roots = uniqueUsageChartRoots(paths);
          debug.chartCount = roots.length;
          const candidates = roots.map(root => {
            const chartPaths = paths.filter(path => usageChartRootForPath(path) === root);
            const title = nearestChartTitleTextForRoot(root);
            const titleScore = usageBreakdownTitleScore(title);
            const parsed = parseUsageBreakdownFromChartPaths(chartPaths, legendMapForUsageChartRoot(root));
            return {
              root,
              title,
              titleScore,
              pathCount: chartPaths.length,
              ...parsed,
              score: titleScore + parsed.score
            };
          }).filter(candidate => candidate.breakdown.length > 0);
          const rejectedTitleCandidates = candidates.filter(candidate => candidate.titleScore < 0);
          const titledCandidates = candidates.filter(candidate => candidate.titleScore > 0);
          const unknownTitleCandidates = candidates.filter(candidate => candidate.titleScore === 0);
          const eligibleCandidates = titledCandidates;
          eligibleCandidates.sort((a, b) => b.score - a.score);
          debug.eligibleCandidateCount = eligibleCandidates.length;
          debug.selectedCandidateTitle = eligibleCandidates[0] ? eligibleCandidates[0].title : null;
          if (eligibleCandidates.length === 0 && candidates.length > 0) {
            if (unknownTitleCandidates.length > 0) {
              debug.error = 'No English usage breakdown chart title found. Candidate titles: ' +
                candidates.map(candidate => candidate.title || 'Untitled chart').join(', ');
            } else if (rejectedTitleCandidates.length > 0) {
              debug.error = 'Only non-usage chart candidates found: ' +
                rejectedTitleCandidates.map(candidate => candidate.title || 'Untitled chart').join(', ');
            }
          }
          debug.candidateSummaries = candidates.slice(0, 6).map(candidate => ({
            title: candidate.title,
            titleScore: candidate.titleScore,
            pathCount: candidate.pathCount,
            dayCount: candidate.breakdown.length,
            pointCount: candidate.pointCount,
            serviceCount: candidate.services.length,
            likelyCodexServiceCount: candidate.likelyCodexServiceCount,
            services: candidate.services.slice(0, 8)
          }));

          const breakdown = eligibleCandidates[0] ? eligibleCandidates[0].breakdown : [];
          const json = (breakdown.length > 0) ? JSON.stringify(breakdown) : null;
          window.__codexbarUsageBreakdownJSON = json;
          window.__codexbarUsageBreakdownDebug = json ? null : JSON.stringify(debug);
          return json;
        } catch {
          return null;
        }
      })();
      const usageBreakdownDebug = (() => {
        try {
          return window.__codexbarUsageBreakdownDebug || null;
        } catch {
          return null;
        }
      })();
      const usageBreakdownError = (() => {
        try {
          if (!usageBreakdownDebug) return null;
          const parsed = JSON.parse(usageBreakdownDebug);
          return parsed && parsed.error ? String(parsed.error) : null;
        } catch {
          return null;
        }
      })();
      const bodyText = document.body ? String(document.body.innerText || '').trim() : '';
      const href = window.location ? String(window.location.href || '') : '';
      const workspacePicker = bodyText.includes('Select a workspace');
      const title = document.title ? String(document.title || '') : '';
      const cloudflareInterstitial =
        title.toLowerCase().includes('just a moment') ||
        bodyText.toLowerCase().includes('checking your browser') ||
        bodyText.toLowerCase().includes('cloudflare');
      const authSelector = [
        'input[type="email"]',
        'input[type="password"]',
        'input[name="username"]'
      ].join(', ');
      const hasAuthInputs = !!document.querySelector(authSelector);
      const lower = bodyText.toLowerCase();
      const loginCTA =
        lower.includes('sign in') ||
        lower.includes('log in') ||
        lower.includes('continue with google') ||
        lower.includes('continue with apple') ||
        lower.includes('continue with microsoft');
      const loginRequired =
        href.includes('/auth/') ||
        href.includes('/login') ||
        (hasAuthInputs && loginCTA) ||
        (!hasAuthInputs && loginCTA && href.includes('chatgpt.com'));
      const scrollY = (typeof window.scrollY === 'number') ? window.scrollY : 0;
      const scrollHeight = document.documentElement ? (document.documentElement.scrollHeight || 0) : 0;
      const viewportHeight = (typeof window.innerHeight === 'number') ? window.innerHeight : 0;

      let creditsHeaderPresent = false;
      let creditsHeaderInViewport = false;
      let didScrollToCredits = false;
      let rows = [];
      try {
        const looksLikeCreditsEventRow = (cells) => {
          if (!cells || cells.length < 3) return false;
          const first = String(cells[0] || '');
          const amount = String(cells[2] || '');
          return /\\d{4}|\\d{1,2}[\\/.\\-]\\d{1,2}/.test(first) && /\\d/.test(amount);
        };
        const allTableRows = () => Array.from(document.querySelectorAll('tbody tr')).map(tr => {
          const cells = Array.from(tr.querySelectorAll('td')).map(td => textOf(td));
          return cells;
        }).filter(looksLikeCreditsEventRow);
        const headings = Array.from(document.querySelectorAll('h1,h2,h3'));
        const header = headings.find(h => textOf(h).toLowerCase() === 'credits usage history');
        if (header) {
          creditsHeaderPresent = true;
          const rect = header.getBoundingClientRect();
          creditsHeaderInViewport = rect.top >= 0 && rect.top <= viewportHeight;

          // Only scrape rows from the *credits usage history* table. The page can contain other tables,
          // and treating any <table> as credits history can prevent our scroll-to-load logic from running.
          const container = header.closest('section') || header.parentElement || document;
          const table = container.querySelector('table') || null;
          const scope = table || container;
          rows = Array.from(scope.querySelectorAll('tbody tr')).map(tr => {
            const cells = Array.from(tr.querySelectorAll('td')).map(td => textOf(td));
            return cells;
          }).filter(r => r.length >= 3);
          if (rows.length === 0) {
            rows = allTableRows();
          }
          if (rows.length === 0 && !window.__codexbarDidScrollToCredits) {
            window.__codexbarDidScrollToCredits = true;
            // If the table is virtualized/lazy-loaded, we need to scroll to trigger rendering even if the
            // header is already in view.
            header.scrollIntoView({ block: 'start', inline: 'nearest' });
            if (creditsHeaderInViewport) {
              window.scrollBy(0, Math.max(220, viewportHeight * 0.6));
            }
            didScrollToCredits = true;
          }
        } else if (rows.length === 0 && !window.__codexbarDidScrollToCredits && scrollHeight > viewportHeight * 1.5) {
          rows = allTableRows();
          if (rows.length > 0) {
            creditsHeaderPresent = true;
            creditsHeaderInViewport = true;
          }
        }
        if (rows.length === 0 && !window.__codexbarDidScrollToCredits && scrollHeight > viewportHeight * 1.5) {
          // The credits history section often isn't part of the DOM until you scroll down. Nudge the page
          // once so subsequent scrapes can find the header and rows.
          window.__codexbarDidScrollToCredits = true;
          window.scrollTo(0, Math.max(0, scrollHeight - viewportHeight - 40));
          didScrollToCredits = true;
        }
      } catch {}

      let creditsPurchaseURL = null;
      try {
        const creditsButton = findCreditsPurchaseButton();
        if (creditsButton) {
          const url = purchaseURLFromElement(creditsButton);
          if (url) creditsPurchaseURL = url;
        }
        const candidates = Array.from(document.querySelectorAll('a, button'));
        for (const node of candidates) {
          const label = elementLabel(node);
          if (!purchaseTextMatches(label)) continue;
          const url = purchaseURLFromElement(node);
          if (url) {
            creditsPurchaseURL = url;
            break;
          }
        }
        if (!creditsPurchaseURL) {
          const anchors = Array.from(document.querySelectorAll('a[href]'));
          for (const anchor of anchors) {
            const label = elementLabel(anchor);
            const href = anchor.getAttribute('href') || '';
            const hrefLooksRelevant = /credits|billing/i.test(href);
            if (!hrefLooksRelevant && !purchaseTextMatches(label)) continue;
            const url = normalizeHref(href);
            if (url) {
              creditsPurchaseURL = url;
              break;
            }
          }
        }
      } catch {}

      let signedInEmail = null;
      try {
        const next = window.__NEXT_DATA__ || null;
        const props = (next && next.props && next.props.pageProps) ? next.props.pageProps : null;
        const userEmail = (props && props.user) ? props.user.email : null;
        const sessionEmail = (props && props.session && props.session.user) ? props.session.user.email : null;
        signedInEmail = userEmail || sessionEmail || null;
      } catch {}

      if (!signedInEmail) {
        try {
          const node = document.getElementById('__NEXT_DATA__');
          const raw = node && node.textContent ? String(node.textContent) : '';
          if (raw) {
            const obj = JSON.parse(raw);
            const queue = [obj];
            let seen = 0;
            while (queue.length && seen < 2000 && !signedInEmail) {
              const cur = queue.shift();
              seen++;
              if (!cur) continue;
              if (typeof cur === 'string') {
                if (cur.includes('@')) signedInEmail = cur;
                continue;
              }
              if (typeof cur !== 'object') continue;
              for (const [k, v] of Object.entries(cur)) {
                if (signedInEmail) break;
                if (k === 'email' && typeof v === 'string' && v.includes('@')) {
                  signedInEmail = v;
                  break;
                }
                if (typeof v === 'object' && v) queue.push(v);
              }
            }
          }
        } catch {}
      }

      if (!signedInEmail) {
        try {
          const emailRe = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/ig;
          const found = (bodyText.match(emailRe) || []).map(x => String(x).trim().toLowerCase());
          const unique = Array.from(new Set(found));
          if (unique.length === 1) {
            signedInEmail = unique[0];
          } else if (unique.length > 1) {
            signedInEmail = unique[0];
          }
        } catch {}
      }

      if (!signedInEmail) {
        // Last resort: open the account menu so the email becomes part of the DOM text.
        try {
          const emailRe = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/ig;
          const hasMenu = Boolean(document.querySelector('[role="menu"]'));
          if (!hasMenu) {
            const button =
              document.querySelector('button[aria-haspopup="menu"]') ||
              document.querySelector('button[aria-expanded]');
            if (button && !button.disabled) {
              button.click();
            }
          }
          const afterText = document.body ? String(document.body.innerText || '').trim() : '';
          const found = (afterText.match(emailRe) || []).map(x => String(x).trim().toLowerCase());
          const unique = Array.from(new Set(found));
          if (unique.length === 1) {
            signedInEmail = unique[0];
          } else if (unique.length > 1) {
            signedInEmail = unique[0];
          }
        } catch {}
      }

      return {
        loginRequired,
        workspacePicker,
        cloudflareInterstitial,
        href,
        bodyText,
        bodyHTML: document.documentElement ? String(document.documentElement.outerHTML || '') : '',
        signedInEmail,
        creditsPurchaseURL,
        rows,
        usageBreakdownJSON,
        usageBreakdownDebug,
        usageBreakdownError,
        scrollY,
        scrollHeight,
        viewportHeight,
        creditsHeaderPresent,
        creditsHeaderInViewport,
        didScrollToCredits
      };
    })();

"""
#endif
