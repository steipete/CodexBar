"use client"
import { useState, useEffect } from "react"
import {
  RefreshCw,
  Activity,
  Eye,
  DollarSign,
  Zap,
  Key,
  LayoutDashboard,
  Settings,
  Info,
  LogOut,
  ChevronRight,
  Check,
} from "lucide-react"
import { aiTools } from "./constants"

type FeatureKey = "agents" | "session" | "weekly" | "extra" | "cost"

const showcaseFeatures: { key: FeatureKey; label: string; icon: React.ReactNode; description: string }[] = [
  {
    key: "agents",
    label: "Switch AI Providers",
    icon: <RefreshCw className="size-4" />,
    description: "Quickly toggle between Claude, Cursor, Gemini and more",
  },
  {
    key: "session",
    label: "Track Session Usage",
    icon: <Activity className="size-4" />,
    description: "Monitor your current session limits in real-time",
  },
  {
    key: "weekly",
    label: "Weekly Overview",
    icon: <Eye className="size-4" />,
    description: "See your weekly usage patterns and pace",
  },
  {
    key: "extra",
    label: "Extra Usage Costs",
    icon: <DollarSign className="size-4" />,
    description: "Track additional spending beyond your plan",
  },
  {
    key: "cost",
    label: "Cost Analytics",
    icon: <Zap className="size-4" />,
    description: "Detailed breakdown of tokens and expenses",
  },
]

export function InteractiveShowcase() {
  const [activeFeature, setActiveFeature] = useState<FeatureKey>("agents")
  const [selectedAgent, setSelectedAgent] = useState(1)

  useEffect(() => {
    const interval = setInterval(() => {
      setActiveFeature((prev) => {
        const currentIndex = showcaseFeatures.findIndex((f) => f.key === prev)
        const nextIndex = (currentIndex + 1) % showcaseFeatures.length
        return showcaseFeatures[nextIndex].key
      })
    }, 4000)
    return () => clearInterval(interval)
  }, [])

  useEffect(() => {
    if (activeFeature === "agents") {
      const agentInterval = setInterval(() => {
        setSelectedAgent((prev) => (prev + 1) % 5)
      }, 1000)
      return () => clearInterval(agentInterval)
    }
  }, [activeFeature])

  const agentTabs = [
    { name: "Codex", logo: aiTools[4].logo, color: "#22c55e" },
    { name: "Claude", logo: aiTools[0].logo, color: "#f97316" },
    { name: "Cursor", logo: aiTools[1].logo, color: "#22c55e", rounded: true },
    { name: "Gemini", logo: aiTools[2].logo, color: "#3b82f6" },
    { name: "Copilot", logo: aiTools[3].logo, color: "#22c55e" },
  ]

  return (
    <section className="relative py-32 overflow-hidden bg-[#0a0a0a]">
      <div className="absolute inset-0 overflow-hidden">
        <div className="absolute top-1/2 left-1/4 -translate-y-1/2 w-[600px] h-[600px] bg-gradient-to-r from-[#2F9699]/20 via-[#2964A3]/15 to-transparent blur-[120px] rounded-full" />
        <div className="absolute bottom-0 right-1/4 w-[400px] h-[400px] bg-gradient-to-t from-[#2964A3]/15 to-transparent blur-[100px] rounded-full" />
      </div>

      <div className="absolute bottom-0 left-0 right-0 h-40 bg-gradient-to-b from-transparent to-[#0a0a0a] pointer-events-none" />

      <div className="relative z-10 max-w-7xl mx-auto px-6">
        <div className="text-center mb-16">
          <h2 className="text-3xl md:text-4xl lg:text-5xl font-medium mb-4 text-balance text-white">
            Everything you need, one click away
          </h2>
          <p className="text-gray-400 text-lg max-w-xl mx-auto">
            Access all your AI usage stats instantly from the menu bar
          </p>
        </div>

        <div className="flex flex-col lg:flex-row gap-8 lg:gap-16 items-start">
          <div className="relative flex-shrink-0 w-full lg:w-[420px]">
            <div className="absolute -inset-8 bg-gradient-to-b from-[#2F9699]/10 via-[#2964A3]/5 to-transparent blur-3xl rounded-3xl" />

            <div className="relative bg-[#1c1c1e] rounded-xl shadow-2xl overflow-hidden border border-white/10">
              <div className="bg-[#2c2c2e] px-3 py-2.5 flex items-center gap-2 border-b border-white/5">
                <div className="flex items-center gap-1.5">
                  <div className="w-3 h-3 rounded-full bg-[#ff5f57]" />
                  <div className="w-3 h-3 rounded-full bg-[#febc2e]" />
                  <div className="w-3 h-3 rounded-full bg-[#28c840]" />
                </div>
                <div className="flex-1" />
              </div>

              <div className="p-4">
                <div
                  className={`flex items-center justify-center gap-1 mb-4 transition-all duration-500 ${
                    activeFeature === "agents" ? "scale-105" : activeFeature !== "agents" ? "opacity-50" : ""
                  }`}
                >
                  {agentTabs.map((tab, index) => (
                    <div
                      key={tab.name}
                      className={`flex flex-col items-center px-2.5 py-1.5 rounded-lg transition-all duration-300 ${
                        selectedAgent === index ? "bg-[#2F9699] scale-110" : "hover:bg-white/5"
                      }`}
                    >
                      <div className="size-5 flex items-center justify-center mb-0.5">
                        <img
                          src={tab.logo || "/placeholder.svg"}
                          alt={tab.name}
                          width={20}
                          height={20}
                          className={`${tab.rounded ? "rounded" : ""} ${selectedAgent === index ? "brightness-110" : "opacity-70"}`}
                          style={{ objectFit: "contain" }}
                        />
                      </div>
                      <span
                        className={`text-[9px] font-medium ${selectedAgent === index ? "text-white" : "text-gray-500"}`}
                      >
                        {tab.name}
                      </span>
                      {selectedAgent !== index && (
                        <div className="w-3 h-0.5 rounded-full mt-0.5" style={{ backgroundColor: tab.color }} />
                      )}
                    </div>
                  ))}
                </div>

                <div
                  className={`space-y-3 transition-all duration-500 ${activeFeature !== "agents" && activeFeature !== "session" && activeFeature !== "weekly" ? "opacity-50" : ""}`}
                >
                  <div className="flex items-center justify-between pb-2 border-b border-white/10">
                    <div>
                      <h3 className="font-semibold text-white text-sm">Claude</h3>
                      <p className="text-[10px] text-gray-500">Updated just now</p>
                    </div>
                    <span className="text-xs text-gray-500">Max</span>
                  </div>

                  <div
                    className={`transition-all duration-500 ${activeFeature === "session" ? "scale-105 bg-white/5 px-3 py-2 rounded-lg mx-2" : ""}`}
                  >
                    <h4 className="font-medium text-white text-xs mb-1.5">Session</h4>
                    <div className="h-1 bg-white/10 rounded-full overflow-hidden mb-1">
                      <div className="h-full w-[2%] bg-[#f59e0b] rounded-full" />
                    </div>
                    <div className="flex justify-between text-[10px] text-gray-500">
                      <span>2% used</span>
                      <span>Resets in 4h 28m</span>
                    </div>
                  </div>

                  <div
                    className={`transition-all duration-500 ${activeFeature === "weekly" ? "scale-105 bg-white/5 px-3 py-2 rounded-lg mx-2" : ""}`}
                  >
                    <h4 className="font-medium text-white text-xs mb-1.5">Weekly</h4>
                    <div className="h-1 bg-white/10 rounded-full overflow-hidden mb-1">
                      <div className="h-full w-[5%] bg-[#f59e0b] rounded-full" />
                    </div>
                    <div className="flex justify-between text-[10px] text-gray-500">
                      <span>5% used</span>
                      <span>Resets in 4d 12h</span>
                    </div>
                    <p className="text-[9px] text-gray-600 mt-0.5">Pace: Behind (-38%) · Lasts to reset</p>
                  </div>
                </div>

                <div
                  className={`mt-3 transition-all duration-500 ${activeFeature !== "agents" && activeFeature !== "session" && activeFeature !== "weekly" ? "opacity-50" : ""}`}
                >
                  <h4 className="font-medium text-white text-xs mb-1.5">Sonnet</h4>
                  <div className="h-1 bg-white/10 rounded-full overflow-hidden mb-1" />
                  <p className="text-[10px] text-gray-500">0% used</p>
                </div>

                <div
                  className={`mt-3 pt-3 border-t border-white/10 transition-all duration-500 ${activeFeature === "extra" ? "scale-105 bg-white/5 px-3 py-2 rounded-lg mx-2 border-0" : activeFeature !== "extra" && activeFeature !== "cost" ? "opacity-50" : ""}`}
                >
                  <h4 className="font-medium text-white text-xs mb-1.5">Extra usage</h4>
                  <div className="h-1 bg-white/10 rounded-full overflow-hidden mb-1" />
                  <div className="flex justify-between text-[10px] text-gray-500">
                    <span>This month: $ 0.00 / $ 2000.00</span>
                    <span>0% used</span>
                  </div>
                </div>

                <div
                  className={`mt-3 pt-3 border-t border-white/10 space-y-2 transition-all duration-500 ${activeFeature === "cost" ? "scale-105 bg-white/5 px-3 py-2 rounded-lg mx-2 border-0" : activeFeature !== "extra" && activeFeature !== "cost" ? "opacity-50" : ""}`}
                >
                  <div className="flex items-center justify-between">
                    <h4 className="font-medium text-white text-xs">Cost</h4>
                    <ChevronRight className="size-3 text-gray-600" />
                  </div>
                  <p className="text-[10px] text-gray-500 mt-1">Today: $ 0.04 · 15K tokens</p>
                  <p className="text-[10px] text-gray-500">Last 30 days: $ 254.24 · 218M tokens</p>
                </div>

                <div
                  className={`mt-3 pt-3 border-t border-white/10 space-y-2 transition-all duration-500 ${activeFeature !== "agents" ? "opacity-30" : ""}`}
                >
                  <div className="flex items-center gap-2 text-xs text-gray-400 hover:text-white cursor-pointer transition-colors">
                    <Key className="size-3" />
                    <span>Add Account...</span>
                  </div>
                  <div className="flex items-center gap-2 text-xs text-gray-400 hover:text-white cursor-pointer transition-colors">
                    <LayoutDashboard className="size-3" />
                    <span>Usage Dashboard</span>
                  </div>
                  <div className="flex items-center gap-2 text-xs text-gray-400 hover:text-white cursor-pointer transition-colors">
                    <Activity className="size-3" />
                    <span>Status Page</span>
                  </div>
                </div>

                <div
                  className={`mt-3 pt-3 border-t border-white/10 space-y-2 transition-all duration-500 ${activeFeature !== "agents" ? "opacity-30" : ""}`}
                >
                  <div className="flex items-center gap-2 text-xs text-gray-400 hover:text-white cursor-pointer transition-colors">
                    <Settings className="size-3" />
                    <span>Settings...</span>
                  </div>
                  <div className="flex items-center gap-2 text-xs text-gray-400 hover:text-white cursor-pointer transition-colors">
                    <Info className="size-3" />
                    <span>About CodexBar</span>
                  </div>
                  <div className="flex items-center gap-2 text-xs text-gray-400 hover:text-white cursor-pointer transition-colors">
                    <LogOut className="size-3" />
                    <span>Quit</span>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div className="flex-1 space-y-4">
            <div className="mb-8">
              <h3 className="text-2xl font-medium text-white mb-2">Features</h3>
            </div>

            {showcaseFeatures.map((feature) => (
              <button
                key={feature.key}
                onClick={() => setActiveFeature(feature.key)}
                className={`w-full text-left p-4 rounded-none border-2 transition-all duration-500 group ${
                  activeFeature === feature.key
                    ? "bg-[#2F9699]/10 border-[#2F9699] border-dashed"
                    : "bg-[#0a0a0a] border-white/10 border-dashed hover:border-white/20 hover:bg-white/[0.02]"
                }`}
              >
                <div className="flex items-center gap-4">
                  <div
                    className={`size-11 rounded-xl flex items-center justify-center transition-all duration-300 ${
                      activeFeature === feature.key
                        ? "bg-[#2F9699] text-white"
                        : "bg-white/5 text-gray-500 group-hover:text-gray-300"
                    }`}
                  >
                    {feature.icon}
                  </div>
                  <div className="flex-1">
                    <h3
                      className={`font-medium transition-colors ${
                        activeFeature === feature.key ? "text-white" : "text-gray-400 group-hover:text-gray-200"
                      }`}
                    >
                      {feature.label}
                    </h3>
                    <p
                      className={`text-sm mt-0.5 transition-colors ${
                        activeFeature === feature.key ? "text-gray-400" : "text-gray-600 group-hover:text-gray-500"
                      }`}
                    >
                      {feature.description}
                    </p>
                  </div>
                  {activeFeature === feature.key && (
                    <div className="size-6 rounded-full bg-[#2F9699] flex items-center justify-center">
                      <Check className="size-3.5 text-white" />
                    </div>
                  )}
                </div>
              </button>
            ))}
          </div>
        </div>
      </div>
    </section>
  )
}

