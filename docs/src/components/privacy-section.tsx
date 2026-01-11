"use client"
import { Cookie, Terminal } from "lucide-react"
import { browsers } from "./constants"

export function PrivacySection() {
  return (
    <section className="relative py-32 bg-[#0a0a0a]">
      <div className="max-w-7xl mx-auto px-6">
        <div className="text-center mb-16">
          <h2 className="text-4xl md:text-5xl lg:text-6xl font-medium mb-4 text-balance text-white">
            Your data stays yours
          </h2>
          <p className="text-gray-400 text-lg md:text-xl max-w-2xl mx-auto text-balance">
            No passwords stored. No tracking. Just seamless access using your existing browser sessions.
          </p>
        </div>

        <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
          {/* Browser Cookie Authentication Box */}
          <div className="border border-dashed border-white/10 rounded-xl overflow-hidden">
            <div className="bg-[#111111] px-8 py-6 border-b border-dashed border-white/10">
              <div className="flex items-start gap-4">
                <div className="size-12 rounded-xl bg-gradient-to-br from-[#2F9699]/20 to-[#2964A3]/20 flex items-center justify-center border border-white/5 shrink-0">
                  <Cookie className="size-6 text-[#2F9699]" />
                </div>
                <div>
                  <h3 className="text-2xl font-semibold text-white mb-2">Browser Cookie Authentication</h3>
                  <p className="text-gray-400 leading-relaxed">
                    Reuses existing browser cookies for dashboard access — no passwords stored.
                  </p>
                </div>
              </div>
            </div>

            <div className="grid grid-cols-3">
              {browsers.map((browser, index) => (
                <div
                  key={browser.name}
                  className={`flex flex-col items-center justify-center gap-4 py-12 px-6 bg-[#0a0a0a] ${
                    index < 2 ? "border-r border-dashed border-white/10" : ""
                  }`}
                >
                  <img
                    src={browser.logo || "/placeholder.svg"}
                    alt={`${browser.name} logo`}
                    width={48}
                    height={48}
                    className="object-contain"
                  />
                  <span className="text-white font-medium text-lg">{browser.name}</span>
                </div>
              ))}
            </div>
          </div>

          {/* CLI Fallback Box */}
          <div className="border border-dashed border-white/10 rounded-xl overflow-hidden">
            <div className="bg-[#111111] px-8 py-6 border-b border-dashed border-white/10">
              <div className="flex items-start gap-4">
                <div className="size-12 rounded-xl bg-gradient-to-br from-[#2964A3]/20 to-[#2F9699]/20 flex items-center justify-center border border-white/5 shrink-0">
                  <Terminal className="size-6 text-[#2964A3]" />
                </div>
                <div>
                  <h3 className="text-2xl font-semibold text-white mb-2">Local CLI Fallback</h3>
                  <p className="text-gray-400 leading-relaxed">
                    When cookies are missing, CodexBar falls back to local CLI output.
                  </p>
                </div>
              </div>
            </div>

            <div className="bg-[#0a0a0a] p-8">
              {/* Terminal preview */}
              <div className="bg-[#050505] rounded-lg border border-white/5 overflow-hidden">
                <div className="flex items-center gap-1.5 px-3 py-2 bg-white/5 border-b border-white/5">
                  <div className="size-2.5 rounded-full bg-[#ff5f57]" />
                  <div className="size-2.5 rounded-full bg-[#febc2e]" />
                  <div className="size-2.5 rounded-full bg-[#28c840]" />
                </div>
                <div className="p-4 font-mono text-sm">
                  <div className="flex items-center gap-2 text-gray-500">
                    <span>$</span>
                    <span className="text-gray-300">codexbar status</span>
                  </div>
                  <div className="mt-2 text-[#2F9699]">✓ Using local CLI mode</div>
                  <div className="text-gray-500 text-xs mt-1">No cookies detected - output displayed locally</div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}

