"use client"
import { useState } from "react"
import { Copy, Check } from "lucide-react"
import { FloatingUsageCard } from "./floating-usage-card"
import { aiTools } from "./constants"

export function HeroSection() {
  const [copied1, setCopied1] = useState(false)
  const [copied2, setCopied2] = useState(false)

  return (
    <main className="relative flex items-center justify-center min-h-screen overflow-hidden pt-16">
      <div className="absolute inset-0 overflow-hidden">
        <div className="absolute inset-0 bg-[radial-gradient(circle_at_center,_#1a1a1a_0%,_#0a0a0a_100%)]" />

        <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 w-[100%] h-[100%]">
          <div className="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 rotate-[20deg]">
            <div className="w-[140px] h-[1000px] bg-gradient-to-b from-[#2F9699]/60 via-[#2964A3]/40 to-transparent blur-[80px] absolute -translate-x-[350px] animate-pulse-slow" />
            <div className="w-[140px] h-[1000px] bg-gradient-to-b from-[#2964A3]/60 via-[#2F9699]/40 to-transparent blur-[80px] absolute -translate-x-[120px] animate-pulse-slow animation-delay-500" />
            <div className="w-[140px] h-[1000px] bg-gradient-to-b from-[#2F9699]/60 via-[#2964A3]/40 to-transparent blur-[80px] absolute translate-x-[80px] animate-pulse-slow animation-delay-1000" />
            <div className="w-[140px] h-[1000px] bg-gradient-to-b from-[#2964A3]/60 via-[#2F9699]/40 to-transparent blur-[80px] absolute translate-x-[300px] animate-pulse-slow animation-delay-1500" />
          </div>
        </div>

        <div className="absolute inset-0 bg-[linear-gradient(to_right,#ffffff05_1px,transparent_1px),linear-gradient(to_bottom,#ffffff05_1px,transparent_1px)] bg-[size:64px_64px]" />

        <div className="absolute bottom-0 left-0 right-0 h-80 bg-gradient-to-t from-[#0a0a0a] via-[#0a0a0a]/90 to-transparent" />
      </div>

      {aiTools.map((tool, index) => (
        <FloatingUsageCard key={tool.name} tool={tool} index={index} />
      ))}

      <div className="relative z-10 max-w-4xl mx-auto px-6 text-center">
        <h1 className="text-5xl md:text-6xl lg:text-7xl font-medium mb-6 leading-[1.05] text-balance text-white">
          Stay ahead of resets.
        </h1>
        <p className="text-lg md:text-xl text-gray-300 mb-12 max-w-2xl mx-auto text-balance">
          CodexBar keeps session, weekly limits and credits in the menu bar, so you know when you're safe to ship.
        </p>

        <div className="flex flex-col items-center gap-3 mb-6">
          <div className="w-full max-w-2xl space-y-3">
            <div className="inline-flex items-center gap-3 bg-[#1a1a1a] border border-white/10 rounded-lg px-4 py-3 shadow-lg">
              <span className="text-gray-500 font-mono text-sm">$</span>
              <code className="font-mono text-sm text-gray-300">brew install steipete/formulae/codexbar</code>
              <button
                onClick={() => {
                  navigator.clipboard.writeText("brew install steipete/formulae/codexbar")
                  setCopied1(true)
                  setTimeout(() => setCopied1(false), 2000)
                }}
                className="ml-2 p-1.5 hover:bg-white/10 rounded transition-colors"
                aria-label="Copy command"
              >
                {copied1 ? <Check className="size-4 text-green-400" /> : <Copy className="size-4 text-gray-400" />}
              </button>
            </div>

            <div className="text-sm text-gray-500 text-center">or</div>

            <div className="inline-flex items-center gap-3 bg-[#1a1a1a] border border-white/10 rounded-lg px-4 py-3 shadow-lg">
              <span className="text-gray-500 font-mono text-sm">$</span>
              <code className="font-mono text-sm text-gray-300">brew install steipete/formulae/codexbar-cli</code>
              <button
                onClick={() => {
                  navigator.clipboard.writeText("brew install steipete/formulae/codexbar-cli")
                  setCopied2(true)
                  setTimeout(() => setCopied2(false), 2000)
                }}
                className="ml-2 p-1.5 hover:bg-white/10 rounded transition-colors"
                aria-label="Copy command"
              >
                {copied2 ? <Check className="size-4 text-green-400" /> : <Copy className="size-4 text-gray-400" />}
              </button>
            </div>
            <p className="text-xs text-gray-600 text-center">Linuxbrew (CLI only)</p>
          </div>
        </div>

        <p className="text-sm text-gray-500">Requirements: macOS 14+ (Apple Silicon + Intel).</p>
      </div>
    </main>
  )
}

