"use client"
import { AnimatedProgressBar } from "./animated-progress-bar"
import { aiTools } from "./constants"

export function FloatingUsageCard({
  tool,
  index,
}: {
  tool: (typeof aiTools)[0]
  index: number
}) {
  const positions = [
    { top: "20%", left: "12%", rotate: "-6deg" },
    { top: "28%", right: "12%", rotate: "4deg" },
    { bottom: "25%", left: "10%", rotate: "3deg" },
    { bottom: "25%", right: "12%", rotate: "-4deg" },
    { top: "42%", left: "9%", rotate: "-2deg" },
  ]

  const pos = positions[index] || positions[0]

  return (
    <div
      className="absolute hidden lg:block animate-float backdrop-blur-md bg-white/5 border border-white/10 rounded-xl p-4 shadow-2xl min-w-[200px]"
      style={{
        ...pos,
        animationDelay: `${index * 0.5}s`,
      }}
    >
      <div className="flex items-center gap-3 mb-3">
        <div className={`size-7 flex items-center justify-center ${tool.rounded ? "rounded-lg" : ""}`}>
          <img
            src={tool.logo || "/placeholder.svg"}
            alt={`${tool.name} logo`}
            width={28}
            height={28}
            className={`${tool.rounded ? "rounded-lg" : ""}`}
            style={{ objectFit: "contain" }}
          />
        </div>
        <span className="text-white font-medium text-sm">{tool.name}</span>
      </div>
      <AnimatedProgressBar
        progress={tool.progress}
        color={tool.color}
        delay={500 + index * 200}
        multiGradient={tool.multiGradient}
      />
      <div className="flex justify-between mt-2 text-xs">
        <span className="text-gray-400">{tool.progress}% used</span>
        <span className="text-gray-500">Resets in 2h</span>
      </div>
    </div>
  )
}

