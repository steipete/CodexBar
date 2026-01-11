"use client"
import { Button } from "@/components/ui/button"

export function Navigation() {
  return (
    <nav className="fixed top-0 w-full z-50 border-b border-white/10 bg-[#0a0a0a]/80 backdrop-blur-md">
      <div className="mx-auto max-w-7xl px-6">
        <div className="flex h-16 items-center justify-between">
          <div className="flex items-center gap-8">
            <div className="flex items-center gap-2">
              <img src="/icon.png" alt="CodexBar" className="size-6 rounded-md" />
              <span className="font-semibold text-lg">CodexBar</span>
            </div>
            <div className="hidden md:flex items-center gap-6 text-sm text-gray-400">
              <a href="https://github.com/steipete/CodexBar" className="hover:text-white transition-colors">
                Source
              </a>
              <a
                href="https://github.com/steipete/CodexBar/blob/main/docs/providers.md"
                className="hover:text-white transition-colors"
              >
                Docs
              </a>
              <a
                href="https://github.com/steipete/CodexBar/blob/main/docs/cli.md"
                className="hover:text-white transition-colors"
              >
                CLI
              </a>
              <a
                href="https://github.com/steipete/CodexBar/blob/main/docs/provider.md"
                className="hover:text-white transition-colors"
              >
                Provider guide
              </a>
              <a
                href="https://github.com/steipete/CodexBar/blob/main/CHANGELOG.md"
                className="hover:text-white transition-colors"
              >
                Changelog
              </a>
            </div>
          </div>
          <div className="flex items-center gap-4">
            <a href="https://github.com/steipete/CodexBar/releases/tag/v0.17.0" target="_blank" rel="noopener noreferrer">
              <Button className="bg-white text-black hover:bg-gray-100 gap-2">
                Download latest
              </Button>
            </a>
          </div>
        </div>
      </div>
    </nav>
  )
}

