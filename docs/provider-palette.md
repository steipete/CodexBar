---
summary: "Audited provider accents, official sources, and fixed-surface contrast decisions for the September 2026 palette refresh."
read_when:
  - Updating provider brand colors or website palette data
  - Reviewing palette contrast or regenerating the social preview
---

# Provider palette audit

The September 28, 2026 audit of #4075 adopts 16 officially supported accents. Eleven proposed values remain
unverified, and nine other proposals materially reduce contrast on a tested surface, so those accents stay unchanged.
Menu-bar icons remain system-tinted templates. Existing widget colors and Moonshot's `#121212` confetti ink are preserved.
Original confetti entries are retained where a replacement is unsupported; supporting colors are not being recertified.
All touched Swift color values use `ProviderColor(hex:)`.

The controlled comparison uses white and `#222222` for light/dark menu-card surfaces. A material
regression means falling below 3:1 while losing at least 0.5 in contrast ratio compared with the previous accent.
This is a non-regression check, not an accessibility certification of translucent desktop backgrounds or existing
colors. Widgets keep their previous RGB values. Highlighted menu rows use the system selection tint instead.
Old decimal RGB values are expressed as their nearest 8-bit sRGB hex (at most half a channel step of rounding).

“Supported” means the exact proposed value was found in an official asset or site stylesheet; it does not mean
it is that provider's only canonical brand color. In particular, Copilot's match is a GitHub Primer Brand palette token.
“Unverified” means the old accent is retained, not that the old value has been newly certified.

The website's provider cards and social preview entries use the final accent below. The social preview deliberately
shows a subset of providers; regenerate its PNG and receipt together using [social-card.md](social-card.md).

| Provider ID | Old | Proposed | Final | Official source | Contrast / decision |
| --- | --- | --- | --- | --- | --- |
| abacus | `#38BDF8` | `#814EE8` | `#814EE8` | [Source](https://abacus.ai/) | Adopt; light 2.14 → 5.01:1; dark 3.17:1. |
| aiand | `#E25C2B` | `#C70007` | `#E25C2B` | [Source](https://aiand.com/) | Retain: dark 4.39 → 2.60:1. |
| amp | `#DC2626` | `#F34E3F` | `#F34E3F` | [Source](https://ampcode.com/_app/immutable/assets/app.ba81f8aee8e1c823.css) | Adopt; light 4.83 → 3.52:1; dark 4.52:1. |
| augment | `#6366F1` | `#1AA049` | `#1AA049` | [Source](https://www.augmentcode.com/) | Adopt; light 4.47 → 3.40:1; dark 4.67:1. |
| bedrock | `#FF9900` | `#01A88D` | `#01A88D` | [Source](https://d1.awsstatic.com/onedam/marketing-channels/website/public/shared/architecture-icon-release/Icon-package_07312026.5846e92413caa21490223536cc97f1269e44fa92.zip) | Adopt; light 2.14 → 3.01:1; dark 5.29:1. |
| chutes | `#3184FF` | `#63D297` | `#3184FF` | [Source](https://chutes.ai/) | Retain: light 3.57 → 1.88:1. |
| clawrouter | `#596EF6` | `#1F5AE0` | `#596EF6` | [Source](https://clawrouter.openclaw.ai/) | Unverified; retain. Not publicly established |
| clinepass | `#61A3FA` | `#5487C8` | `#5487C8` | [Source](https://cline.bot/_next/static/css/0b73be6370d7bf9c.css) | Adopt; light 2.58 → 3.70:1; dark 4.30:1. |
| codebuff | `#44FF00` | `#00FF95` | `#00FF95` | [Source](https://www.codebuff.com/_next/static/css/17f29cc619045efe.css) | Adopt; light 1.35 → 1.33:1; dark 11.92:1. |
| commandcode | `#A04DFD` | `#8C4EDD` | `#8C4EDD` | [Source](https://commandcode.ai/) | Adopt; light 4.22 → 4.94:1; dark 3.22:1. |
| copilot | `#A855F7` | `#8534F3` | `#A855F7` | [Source](https://github.githubassets.com/assets/primer-react-brand-css.6a01c236ff527e7e.module.css) | Retain: dark 4.02 → 2.87:1. |
| cursor | `#00BFA5` | `#F54E00` | `#F54E00` | [Source](https://cursor.com/marketing-static/_next/static/chunks/06.4i9gbk_pby.css?dpl=dpl_Dqjhj2DDxxLKm2kkipuJt7ret4zo) | Adopt; light 2.33 → 3.52:1; dark 4.52:1. |
| deepseek | `#527DF0` | `#4D6BFE` | `#4D6BFE` | [Source](https://www.deepseek.com/_next/static/css/3da1ce676c85d262.css) | Adopt; light 3.78 → 4.33:1; dark 3.67:1. |
| deepgram | `#6467F2` | `#13EF93` | `#6467F2` | [Source](https://deepgram.com/) | Retain: light 4.41 → 1.52:1. |
| devin | `#46B482` | `#317CFF` | `#317CFF` | [Source](https://devin.ai/_next/static/immutable/chunks/111m80s9d-n0-.css) | Adopt; light 2.59 → 3.85:1; dark 4.13:1. |
| doubao | `#3370FF` | `#0057FF` | `#3370FF` | [Source](https://www.doubao.com/) | Retain: dark 3.71 → 2.88:1. |
| fireworks | `#F25B1C` | `#6720FF` | `#F25B1C` | [Source](https://fireworks.ai/) | Retain: dark 4.76 → 2.45:1. |
| groq | `#F56844` | `#F55036` | `#F56844` | [Source](https://groq.com/) | Unverified; retain. #F43E01 |
| jetbrains | `#FF3399` | `#955AE0` | `#FF3399` | [Source](https://www.jetbrains.com/ai/) | Unverified; retain. #6B57FF |
| kilo | `#F27027` | `#FAF74F` | `#F27027` | [Source](https://kilo.ai/) | Unverified; retain. #F8F676 (rounded sRGB) |
| kimi | `#FE603C` | `#007CFF` | `#FE603C` | [Source](https://www.kimi.com/) | Unverified; retain. No verified #007CFF |
| kiro | `#FF9900` | `#9046FF` | `#9046FF` | [Source](https://kiro.dev/_next/static/css/0238e231f83df5bb.css) | Adopt; light 2.14 → 4.66:1; dark 3.41:1. |
| litellm | `#4C89F0` | `#5B3FD1` | `#4C89F0` | [Source](https://www.litellm.ai/) | Retain: dark 4.65 → 2.33:1. |
| longcat | `#FFD100` | `#29E154` | `#29E154` | [Source](https://s3plus.meituan.net/aigc-media-resources/longcat/yeqian-logo.svg) | Adopt; light 1.46 → 1.75:1; dark 9.09:1. |
| mistral | `#FF500F` | `#FF5229` | `#FF5229` | [Source](https://mistral.ai/_astro/astro.BOPo2zPB.css) | Adopt; light 3.28 → 3.24:1; dark 4.92:1. |
| moonshot | `#205DEB` | `#007CFF` | `#205DEB` | [Source](https://platform.moonshot.ai/) | Unverified; retain. Neutral primary; no verified #007CFF |
| neuralwatt | `#38D98C` | `#D55934` | `#D55934` | [Source](https://cdn.prod.website-files.com/693d9776ae14be12d60f5996/css/neural-watt.webflow.shared.5b3762da8.css) | Adopt; light 1.83 → 3.96:1; dark 4.02:1. |
| notion | `#337EA9` | `#2EAADC` | `#337EA9` | [Source](https://www.notion.com/) | Unverified; retain. #2383E2 (UI blue) |
| opencode | `#3B82F6` | `#3B7DD8` | `#3B82F6` | [Source](https://opencode.ai/brand) | Unverified; retain. #007AFF (UI accent); grayscale logo |
| perplexity | `#20B2AA` | `#20808D` | `#20B2AA` | [Source](https://www.perplexity.ai/hub/brand) | Unverified; retain. No verified #20808D |
| qoder | `#10B981` | `#2ADB5C` | `#10B981` | [Source](https://g.alicdn.com/Qoder/qoder-web/0.0.311/_next/static/css/4cb09c403c0c207d.css) | Retain: light 2.54 → 1.84:1. |
| sakana | `#2975DB` | `#CC2B2B` | `#2975DB` | [Source](https://sakana.ai/) | Retain: dark 3.53 → 2.99:1. |
| sub2api | `#2DC6D8` | `#14B8A6` | `#14B8A6` | [Source](https://raw.githubusercontent.com/Wei-Shaw/sub2api/main/frontend/tailwind.config.js) | Adopt; light 2.06 → 2.49:1; dark 6.39:1. |
| t3chat | `#F56647` | `#A3004C` | `#F56647` | [Source](https://t3.chat/) | Unverified; retain. Not established |
| venice | `#3399FF` | `#3C8FDD` | `#3C8FDD` | [Source](https://cdn.venice.ai/_next/static/immutable/chunks/1z9-rwfn_gg4b.css) | Adopt; light 2.94 → 3.41:1; dark 4.67:1. |
| warp | `#938BB4` | `#01A4FF` | `#938BB4` | [Source](https://www.warp.dev/press) | Unverified; retain. #C7AEFF and #1C1A26 in official logo |
