import CodexBarCore
import Foundation

enum LinuxDashboardRenderer {
    static func renderHTML(
        snapshot: LinuxDashboardSnapshot,
        refreshSeconds: Int,
        outputDirectory: URL) -> String
    {
        let generated = Self.timestampFormatter.string(from: snapshot.generatedAt)
        let cards = snapshot.providers
            .sorted { lhs, rhs in
                if (lhs.error != nil) != (rhs.error != nil) {
                    return lhs.error != nil
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
            .map(Self.renderCard)
            .joined(separator: "\n")

        let outputPath = Self.escapeHTML(outputDirectory.path)
        let summary = Self.escapeHTML(snapshot.topSummary)
        let headline = Self.escapeHTML(snapshot.headline)

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta http-equiv="refresh" content="\(max(10, refreshSeconds))">
          <title>CodexBar Linux</title>
          <style>
            :root {
              --bg: #f4efe4;
              --panel: rgba(255, 252, 245, 0.84);
              --panel-strong: rgba(255, 248, 237, 0.96);
              --ink: #1f1b16;
              --muted: #685f53;
              --line: rgba(73, 54, 31, 0.14);
              --accent: #a5441d;
              --accent-soft: rgba(165, 68, 29, 0.14);
              --ok: #1f7a45;
              --warn: #9f5b00;
              --error: #a11d33;
              --shadow: 0 18px 50px rgba(84, 55, 26, 0.14);
              --radius: 22px;
              --radius-sm: 14px;
              --font-sans: "Avenir Next", "Segoe UI", "Liberation Sans", sans-serif;
              --font-serif: "Iowan Old Style", "Palatino Linotype", "Book Antiqua", serif;
            }
            * { box-sizing: border-box; }
            body {
              margin: 0;
              font-family: var(--font-sans);
              color: var(--ink);
              background:
                radial-gradient(circle at top left, rgba(255,255,255,0.75), transparent 28%),
                radial-gradient(circle at right 20%, rgba(236, 182, 133, 0.24), transparent 18%),
                linear-gradient(160deg, #f8f2e7 0%, #f0e5d2 42%, #eadbc4 100%);
              min-height: 100vh;
            }
            .shell {
              max-width: 1200px;
              margin: 0 auto;
              padding: 40px 20px 56px;
            }
            .hero {
              background: linear-gradient(135deg, rgba(255,255,255,0.72), rgba(255,245,231,0.92));
              border: 1px solid var(--line);
              border-radius: 30px;
              box-shadow: var(--shadow);
              padding: 28px;
              position: relative;
              overflow: hidden;
            }
            .hero::after {
              content: "";
              position: absolute;
              inset: auto -10% -35% 52%;
              height: 220px;
              background: radial-gradient(circle, rgba(165,68,29,0.18), transparent 66%);
              pointer-events: none;
            }
            .eyebrow {
              font-size: 12px;
              letter-spacing: 0.24em;
              text-transform: uppercase;
              color: var(--muted);
              margin-bottom: 10px;
            }
            h1 {
              margin: 0;
              font-family: var(--font-serif);
              font-size: clamp(34px, 6vw, 58px);
              line-height: 0.95;
            }
            .summary {
              margin: 14px 0 18px;
              color: var(--muted);
              font-size: 18px;
            }
            .meta {
              display: flex;
              flex-wrap: wrap;
              gap: 10px;
              color: var(--muted);
              font-size: 14px;
            }
            .chip {
              border: 1px solid var(--line);
              background: rgba(255,255,255,0.62);
              border-radius: 999px;
              padding: 8px 12px;
            }
            .grid {
              display: grid;
              grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
              gap: 18px;
              margin-top: 24px;
            }
            .card {
              background: var(--panel);
              border: 1px solid var(--line);
              border-radius: var(--radius);
              padding: 18px;
              box-shadow: 0 10px 30px rgba(97, 64, 34, 0.08);
              backdrop-filter: blur(8px);
            }
            .card.error {
              border-color: rgba(161,29,51,0.28);
              background: linear-gradient(180deg, rgba(255,249,249,0.96), rgba(255,239,241,0.96));
            }
            .card-head {
              display: flex;
              justify-content: space-between;
              gap: 12px;
              align-items: flex-start;
              margin-bottom: 16px;
            }
            .title {
              margin: 0;
              font-size: 22px;
              font-weight: 700;
            }
            .subtitle {
              margin-top: 4px;
              color: var(--muted);
              font-size: 13px;
            }
            .badges {
              display: flex;
              flex-wrap: wrap;
              gap: 8px;
              justify-content: flex-end;
            }
            .badge {
              padding: 7px 10px;
              border-radius: 999px;
              font-size: 12px;
              font-weight: 700;
              letter-spacing: 0.02em;
              border: 1px solid transparent;
              background: rgba(31, 27, 22, 0.08);
            }
            .badge.source {
              background: var(--accent-soft);
              color: var(--accent);
            }
            .badge.ok { background: rgba(31,122,69,0.12); color: var(--ok); }
            .badge.warn { background: rgba(159,91,0,0.12); color: var(--warn); }
            .badge.error { background: rgba(161,29,51,0.12); color: var(--error); }
            .lane {
              margin-top: 14px;
              padding: 12px 13px;
              border-radius: var(--radius-sm);
              background: var(--panel-strong);
              border: 1px solid rgba(73,54,31,0.08);
            }
            .lane-top {
              display: flex;
              justify-content: space-between;
              gap: 10px;
              align-items: baseline;
            }
            .lane-label {
              font-size: 13px;
              text-transform: uppercase;
              letter-spacing: 0.12em;
              color: var(--muted);
            }
            .lane-value {
              font-weight: 700;
              font-size: 15px;
            }
            .bar {
              height: 9px;
              border-radius: 999px;
              background: rgba(31, 27, 22, 0.08);
              overflow: hidden;
              margin: 10px 0 8px;
            }
            .fill {
              height: 100%;
              background: linear-gradient(90deg, #d96a2d 0%, #a5441d 100%);
              border-radius: inherit;
            }
            .lane-meta {
              font-size: 13px;
              color: var(--muted);
            }
            .stack {
              display: grid;
              gap: 8px;
              margin-top: 14px;
            }
            .stack-row {
              font-size: 14px;
              color: var(--muted);
            }
            .actions {
              display: flex;
              flex-wrap: wrap;
              gap: 10px;
              margin-top: 16px;
            }
            .link {
              display: inline-flex;
              align-items: center;
              gap: 6px;
              border-radius: 999px;
              padding: 9px 12px;
              text-decoration: none;
              color: var(--ink);
              background: rgba(255,255,255,0.7);
              border: 1px solid var(--line);
            }
            .error-copy {
              color: var(--error);
              font-weight: 600;
              line-height: 1.5;
              margin-top: 8px;
            }
            @media (max-width: 720px) {
              .shell { padding: 18px 12px 32px; }
              .hero { padding: 20px; }
              .card-head { flex-direction: column; }
              .badges { justify-content: flex-start; }
            }
          </style>
        </head>
        <body>
          <main class="shell">
            <section class="hero">
              <div class="eyebrow">Ubuntu Dashboard</div>
              <h1>CodexBar Linux</h1>
              <p class="summary">\(headline)<br>\(summary)</p>
              <div class="meta">
                <span class="chip">Actualizado \(generated)</span>
                <span class="chip">Refresco automatico cada \(refreshSeconds)s</span>
                <span class="chip">Salida en \(outputPath)</span>
              </div>
            </section>
            <section class="grid">
              \(cards.isEmpty ? "<article class=\"card\"><p>No hay datos todavia. Lanza providers en la configuracion y espera el siguiente refresh.</p></article>" : cards)
            </section>
          </main>
        </body>
        </html>
        """
    }

    static func renderFailureHTML(
        message: String,
        refreshSeconds: Int,
        outputDirectory: URL) -> String
    {
        let snapshot = LinuxDashboardSnapshot(generatedAt: Date(), providers: [])
        let base = Self.renderHTML(snapshot: snapshot, refreshSeconds: refreshSeconds, outputDirectory: outputDirectory)
        let escaped = Self.escapeHTML(message)
        return base.replacingOccurrences(
            of: "</section>\n            <section class=\"grid\">",
            with: """
            <div class="actions">
              <span class="chip">Sin backend disponible</span>
            </div>
            </section>
            <section class="grid">
              <article class="card error">
                <div class="card-head">
                  <div>
                    <h2 class="title">No se pudo actualizar CodexBar Linux</h2>
                    <div class="subtitle">El frontend Linux depende de CodexBarCLI</div>
                  </div>
                  <div class="badges">
                    <span class="badge error">backend error</span>
                  </div>
                </div>
                <div class="error-copy">\(escaped)</div>
              </article>
            """)
    }

    private static func renderCard(_ payload: LinuxProviderPayload) -> String {
        let subtitleBits = [payload.version, payload.account].compactMap(\.self)
        let subtitle = subtitleBits.isEmpty ? "Sin cuenta asociada" : subtitleBits.joined(separator: " | ")
        let cardClass = payload.error == nil ? "card" : "card error"
        let badges = [
            "<span class=\"badge source\">\(Self.escapeHTML(payload.source))</span>",
            Self.renderStatusBadge(payload),
        ].compactMap(\.self).joined(separator: "\n")

        var body: [String] = []
        if let error = payload.error {
            body.append("<div class=\"error-copy\">\(Self.escapeHTML(error.message))</div>")
        }
        if let metadata = payload.metadata {
            if let primary = payload.usage?.primary {
                body.append(Self.renderLane(label: metadata.sessionLabel, window: primary))
            }
            if let secondary = payload.usage?.secondary {
                body.append(Self.renderLane(label: metadata.weeklyLabel, window: secondary))
            }
            if let tertiary = payload.usage?.tertiary {
                let label = metadata.opusLabel ?? "Extra"
                body.append(Self.renderLane(label: label, window: tertiary))
            }
        } else if let primary = payload.usage?.primary {
            body.append(Self.renderLane(label: "Usage", window: primary))
        }

        if let credits = payload.credits {
            let value = Self.escapeHTML(UsageFormatter.creditsString(from: credits.remaining))
            body.append("""
            <div class="lane">
              <div class="lane-top">
                <span class="lane-label">Creditos</span>
                <span class="lane-value">\(value)</span>
              </div>
            </div>
            """)
        }

        let stackLines = payload.identityLines.map { "<div class=\"stack-row\">\(Self.escapeHTML($0))</div>" }
        if !stackLines.isEmpty {
            body.append("<div class=\"stack\">\(stackLines.joined(separator: ""))</div>")
        }

        let actionLinks = [
            payload.dashboardURL.map { url in
                "<a class=\"link\" href=\"\(Self.escapeAttribute(url))\">Dashboard</a>"
            },
            payload.statusURL.map { url in
                "<a class=\"link\" href=\"\(Self.escapeAttribute(url))\">Status</a>"
            },
        ].compactMap(\.self)
        if !actionLinks.isEmpty {
            body.append("<div class=\"actions\">\(actionLinks.joined(separator: ""))</div>")
        }

        if body.isEmpty {
            body.append("<div class=\"stack-row\">Sin datos de uso todavia.</div>")
        }

        return """
        <article class="\(cardClass)">
          <div class="card-head">
            <div>
              <h2 class="title">\(Self.escapeHTML(payload.displayName))</h2>
              <div class="subtitle">\(Self.escapeHTML(subtitle))</div>
            </div>
            <div class="badges">
              \(badges)
            </div>
          </div>
          \(body.joined(separator: "\n"))
        </article>
        """
    }

    private static func renderStatusBadge(_ payload: LinuxProviderPayload) -> String? {
        if payload.error != nil {
            return "<span class=\"badge error\">error</span>"
        }
        guard let status = payload.status else {
            return "<span class=\"badge ok\">ok</span>"
        }
        let indicator = status.indicator.lowercased()
        let cssClass: String
        switch indicator {
        case "none":
            cssClass = "ok"
        case "minor", "unknown", "maintenance":
            cssClass = "warn"
        default:
            cssClass = "error"
        }
        let copy = status.description?.isEmpty == false ? status.description! : indicator
        return "<span class=\"badge \(cssClass)\">\(Self.escapeHTML(copy))</span>"
    }

    private static func renderLane(label: String, window: RateWindow) -> String {
        let remaining = Int(window.remainingPercent.rounded())
        let width = max(0, min(100, remaining))
        let usageLine = UsageFormatter.usageLine(
            remaining: window.remainingPercent,
            used: window.usedPercent,
            showUsed: false)
        let resetLine = UsageFormatter.resetLine(for: window, style: .countdown) ?? "Sin reset reportado"
        return """
        <div class="lane">
          <div class="lane-top">
            <span class="lane-label">\(Self.escapeHTML(label))</span>
            <span class="lane-value">\(Self.escapeHTML(usageLine))</span>
          </div>
          <div class="bar"><div class="fill" style="width: \(width)%"></div></div>
          <div class="lane-meta">\(Self.escapeHTML(resetLine))</div>
        </div>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeAttribute(_ text: String) -> String {
        Self.escapeHTML(text).replacingOccurrences(of: "'", with: "&#39;")
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
