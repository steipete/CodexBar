module.exports = {
  content: ["./docs/index.html", "./docs/site.js"],
  theme: {
    extend: {
      screens: {
        tablet: "769px",
      },
      fontFamily: {
        sans: ["Inter", "-apple-system", "BlinkMacSystemFont", "Segoe UI", "sans-serif"],
        mono: ["SFMono-Regular", "SF Mono", "Menlo", "monospace"],
      },
    },
  },
};
