#if os(macOS)
/// Cheap dashboard readiness probe. Returns flags only and avoids whole-document rendered text.
let openAIDashboardReadinessScript = """

    (() => {
      const textOf = el => {
        const raw = el && typeof el.textContent === 'string' ? el.textContent : '';
        return raw.trim();
      };
      const textFrom = selector => {
        try {
          return Array.from(document.querySelectorAll(selector))
            .map(textOf)
            .filter(Boolean)
            .join(' ');
        } catch {
          return '';
        }
      };
      const href = window.location ? String(window.location.href || '') : '';
      const title = document.title ? String(document.title || '') : '';
      const semanticText = textFrom(
        'h1,h2,h3,h4,p,button,a,[role="button"],[role="heading"],[role="alert"],[role="status"],label');
      const lower = semanticText.toLowerCase();
      const workspaceText = textFrom('[role="dialog"],[role="listbox"],[role="option"]');
      const workspacePicker =
        lower.includes('select a workspace') || workspaceText.toLowerCase().includes('select a workspace');
      const cloudflareInterstitial =
        title.toLowerCase().includes('just a moment') ||
        lower.includes('checking your browser') ||
        lower.includes('cloudflare') ||
        !!document.querySelector('#challenge-running,#challenge-stage,.cf-chl-widget,[data-ray]');
      const authSelector = [
        'input[type="email"]',
        'input[type="password"]',
        'input[name="username"]'
      ].join(', ');
      const hasAuthInputs = !!document.querySelector(authSelector);
      const loginCTA =
        lower.includes('sign in') ||
        lower.includes('log in') ||
        lower.includes('continue with google') ||
        lower.includes('continue with apple') ||
        lower.includes('continue with microsoft');
      let loginRequired =
        href.includes('/auth/') ||
        href.includes('/login') ||
        (hasAuthInputs && loginCTA) ||
        (!hasAuthInputs && loginCTA && href.includes('chatgpt.com'));

      const parseJSONScript = (id) => {
        try {
          const el = document.getElementById(id);
          if (!el) return null;
          return JSON.parse(typeof el.textContent === 'string' ? el.textContent : '');
        } catch {
          return null;
        }
      };

      let signedInEmail = null;
      let authStatus = null;
      try {
        const next = window.__NEXT_DATA__ || null;
        const props = (next && next.props && next.props.pageProps) ? next.props.pageProps : null;
        const userEmail = (props && props.user) ? props.user.email : null;
        const sessionEmail = (props && props.session && props.session.user) ? props.session.user.email : null;
        signedInEmail = userEmail || sessionEmail || null;
      } catch {}
      const clientBootstrap = parseJSONScript('client-bootstrap');
      if (clientBootstrap) {
        try {
          authStatus = typeof clientBootstrap.authStatus === 'string' ? clientBootstrap.authStatus : null;
          if (!signedInEmail) {
            const session = clientBootstrap.session || null;
            const user = (session && session.user) || clientBootstrap.user || null;
            const email = user && typeof user.email === 'string' ? user.email : null;
            if (email && email.includes('@')) signedInEmail = email;
          }
        } catch {}
      }
      if (authStatus && String(authStatus).toLowerCase() !== 'logged_in') {
        loginRequired = true;
      }

      const viewportHeight = (typeof window.innerHeight === 'number') ? window.innerHeight : 0;
      const scrollHeight = document.documentElement ? (document.documentElement.scrollHeight || 0) : 0;
      let creditsHeaderPresent = false;
      let creditsHeaderInViewport = false;
      let didScrollToCredits = false;
      let rowCount = 0;
      try {
        const headings = Array.from(document.querySelectorAll('h1,h2,h3'));
        const header = headings.find(h => textOf(h).toLowerCase() === 'credits usage history');
        if (header) {
          creditsHeaderPresent = true;
          const rect = header.getBoundingClientRect();
          creditsHeaderInViewport = rect.top >= 0 && rect.top <= viewportHeight;
          const container = header.closest('section') || header.parentElement || document;
          const table = container.querySelector('table') || null;
          rowCount = (table || container).querySelectorAll('tbody tr').length;
          if (rowCount === 0 && !window.__codexbarDidScrollToCredits) {
            window.__codexbarDidScrollToCredits = true;
            header.scrollIntoView({ block: 'start', inline: 'nearest' });
            if (creditsHeaderInViewport) {
              window.scrollBy(0, Math.max(220, viewportHeight * 0.6));
            }
            didScrollToCredits = true;
          }
        } else if (!window.__codexbarDidScrollToCredits && scrollHeight > viewportHeight * 1.5) {
          window.__codexbarDidScrollToCredits = true;
          window.scrollTo(0, Math.max(0, scrollHeight - viewportHeight - 40));
          didScrollToCredits = true;
        }
      } catch {}

      let usageBreakdownReady = false;
      try {
        usageBreakdownReady = Boolean(window.__codexbarUsageBreakdownJSON) ||
          document.querySelectorAll('g.recharts-bar-rectangle path.recharts-rectangle').length > 0;
      } catch {}

      const hasCodeReviewSignal = lower.includes('code review');
      const hasDashboardSignal =
        Boolean(signedInEmail) ||
        creditsHeaderPresent ||
        rowCount > 0 ||
        usageBreakdownReady ||
        hasCodeReviewSignal ||
        lower.includes('credits remaining') ||
        lower.includes('rate limit');

      return {
        loginRequired,
        workspacePicker,
        cloudflareInterstitial,
        href,
        signedInEmail,
        authStatus,
        creditsHeaderPresent,
        creditsHeaderInViewport,
        didScrollToCredits,
        rowCount,
        usageBreakdownReady,
        hasCodeReviewSignal,
        hasDashboardSignal
      };
    })();

"""
#endif
