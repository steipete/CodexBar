"use client"

export function Footer() {
  return (
    <footer className="relative py-16 bg-[#0a0a0a] border-t border-white/10">
      <div className="max-w-7xl mx-auto px-6">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-12 mb-12">
          {/* Brand */}
          <div>
            <div className="flex items-center gap-2 mb-4">
              <img src="/icon.png" alt="CodexBar" className="size-6 rounded-md" />
              <span className="font-semibold text-lg">CodexBar</span>
            </div>
            <p className="text-sm text-gray-500">Track your AI limits. Stay in control.</p>
          </div>

          {/* Links */}
          <div>
            <h1 className="text-sm font-semibold text-white mb-4">Resources</h1>
            <div className="flex flex-col gap-2">
              <a
                href="https://github.com/steipete/CodexBar"
                className="text-sm text-gray-400 hover:text-white transition-colors"
              >
                Source
              </a>
              <a
                href="https://github.com/steipete/CodexBar/blob/main/docs/providers.md"
                className="text-sm text-gray-400 hover:text-white transition-colors"
              >
                Docs
              </a>
              <a
                href="https://github.com/steipete/CodexBar/blob/main/docs/cli.md"
                className="text-sm text-gray-400 hover:text-white transition-colors"
              >
                CLI
              </a>
              <a
                href="https://github.com/steipete/CodexBar/blob/main/docs/provider.md"
                className="text-sm text-gray-400 hover:text-white transition-colors"
              >
                Provider guide
              </a>
              <a
                href="https://github.com/steipete/CodexBar/blob/main/CHANGELOG.md"
                className="text-sm text-gray-400 hover:text-white transition-colors"
              >
                Changelog
              </a>
            </div>
          </div>

          {/* Credits */}
          <div>
            <h1 className="text-sm font-semibold text-white mb-4">Built by</h1>
            <p className="text-sm text-gray-400 mb-2">Peter Steinberger</p>
            <div className="flex items-center gap-2 text-sm text-gray-500">
              <a
                href="https://github.com/steipete/CodexBar/blob/main/LICENSE"
                className="hover:text-gray-400 transition-colors"
              >
                MIT
              </a>
              <span>•</span>
              <a href="https://codexbar.app" className="hover:text-gray-400 transition-colors">
                codexbar.app
              </a>
              <span>•</span>
              <a href="https://trimmy.app" className="hover:text-gray-400 transition-colors">
                trimmy.app
              </a>
            </div>
          </div>
        </div>

        <div className="pt-8 border-t border-white/10 text-center text-sm text-gray-500">
          © {new Date().getFullYear()} CodexBar. All rights reserved.
        </div>
      </div>
    </footer>
  )
}

