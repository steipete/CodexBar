"use client"
import { useState, useEffect } from "react"

export function AnimatedProgressBar({
  progress,
  color,
  delay,
  multiGradient,
}: {
  progress: number
  color: string
  delay: number
  multiGradient?: boolean
}) {
  const [width, setWidth] = useState(0)

  useEffect(() => {
    const timer = setTimeout(() => {
      setWidth(progress)
    }, delay)
    return () => clearTimeout(timer)
  }, [progress, delay])

  return (
    <div className="h-1.5 bg-white/10 rounded-full overflow-hidden">
      <div
        className="h-full rounded-full transition-all duration-1000 ease-out"
        style={{
          width: `${width}%`,
          background: multiGradient ? color : undefined,
          backgroundColor: multiGradient ? undefined : color,
          boxShadow: `0 0 10px ${multiGradient ? "#3B82F6" : color}50`,
        }}
      />
    </div>
  )
}

