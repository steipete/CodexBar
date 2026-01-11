"use client"
import { providers } from "./constants"

export function ProvidersSection() {
  return (
    <section className="relative py-32 bg-[#0a0a0a]">
      <div className="max-w-7xl mx-auto px-6">
        <div className="text-center mb-16">
          <h2 className="text-4xl md:text-5xl lg:text-6xl font-medium mb-4 text-balance text-white">
            Supported AI Providers
          </h2>
          <p className="text-gray-400 text-lg md:text-xl max-w-2xl mx-auto text-balance">
            Track usage and costs across all major AI platforms in one place
          </p>
        </div>

        <div className="border border-dashed border-white/10 rounded-xl overflow-hidden">
          <div className="grid grid-cols-2 md:grid-cols-4">
            {providers.slice(0, 4).map((provider, index) => (
              <div
                key={provider.name}
                className={`flex flex-col items-center justify-center gap-4 py-12 px-6 ${
                  index < 3 ? "border-r border-dashed border-white/10" : ""
                }`}
              >
                <img
                  src={provider.logo || "/placeholder.svg"}
                  alt={`${provider.name} logo`}
                  width={48}
                  height={48}
                  className={`object-contain ${provider.name === "Cursor" || provider.name === "z.ai" ? "rounded-md" : ""}`}
                />
                <span className="text-white font-medium text-lg">{provider.name}</span>
              </div>
            ))}
          </div>

          <div className="border-t border-dashed border-white/10" />

          <div className="grid grid-cols-2 md:grid-cols-4">
            {providers.slice(4, 8).map((provider, index) => (
              <div
                key={provider.name}
                className={`flex flex-col items-center justify-center gap-4 py-12 px-6 ${
                  index < 3 ? "border-r border-dashed border-white/10" : ""
                }`}
              >
                <img
                  src={provider.logo || "/placeholder.svg"}
                  alt={`${provider.name} logo`}
                  width={48}
                  height={48}
                  className={`object-contain ${provider.name === "Cursor" || provider.name === "z.ai" ? "rounded-md" : ""}`}
                />
                <span className="text-white font-medium text-lg">{provider.name}</span>
              </div>
            ))}
          </div>

          <div className="border-t border-dashed border-white/10" />

          <div className="grid grid-cols-2 md:grid-cols-3">
            {providers.slice(8, 11).map((provider, index) => (
              <div
                key={provider.name}
                className={`flex flex-col items-center justify-center gap-4 py-12 px-6 ${
                  index < 2 ? "border-r border-dashed border-white/10" : ""
                }`}
              >
                <img
                  src={provider.logo || "/placeholder.svg"}
                  alt={`${provider.name} logo`}
                  width={48}
                  height={48}
                  className={`object-contain ${provider.name === "Cursor" || provider.name === "z.ai" ? "rounded-md" : ""}`}
                />
                <span className="text-white font-medium text-lg">{provider.name}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  )
}

