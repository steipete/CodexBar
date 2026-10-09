---
summary: "Usage & Spend brand artwork provenance and monochrome rendering boundaries."
read_when:
  - Adding or updating colored provider artwork
  - Changing Usage & Spend icon presentation
---

# Usage & Spend provider artwork

Provider-level icons request `ProviderBrandIcon.Style.brand`. Account/source and model child rows
retain CodexBar's existing monochrome provider artwork and 76% opacity, adapting to light and dark
appearance. The existing provider association is preserved. Menu bar and other settings callers
retain the default monochrome rendering.

`Brand-ProviderIcon-*` assets are opt-in. They preserve their stored fills, masks and gradients;
SwiftUI must render them as original images, without applying the configurable chart accent color.
Brand and monochrome requests have separate cached NSImage instances. Curated names use the
provider identifier, since Codex, OpenAI API and Azure OpenAI share a legacy monochrome resource
but must not share the Codex application's product artwork.

If no curated asset exists, or it cannot be decoded, use the existing adaptive template. Existing
provider SVGs often contain white silhouettes and must not simply be switched to original rendering.
This fallback does not assert that the provider has an officially monochrome-only identity.
The OpenCodex source retains its existing branch symbol.

All production Usage & Spend icons share a 20-point slot, including account/source and model child
rows. Transparent padding is compensated for in both brand and monochrome artwork; see
[spend-chart-brand-icons.md](spend-chart-brand-icons.md) for the shared sizing rules.
The filled Bedrock tile renders at 84% of the icon slot; the open Meta and Vertex AI marks render
at 108%. This balances their apparent weight without modifying artwork or colors. Single-model
groups omit the repeated Models heading, while multi-model, multi-source and partial-history groups
retain it. Long model names truncate in the middle and expose the full name in a tooltip.

## Sources

Reviewed 2026-10-01; Codex, Antigravity PNG and cloud icons verified 2026-10-06.
These files identify the corresponding third-party products; their marks remain
the property of their owners. Colors are not sampled from screenshots or chosen from chart palettes.

| Asset | Primary source | Local transformation |
| --- | --- | --- |
| Codex | [Official Codex app](https://openai.com/codex/), signed by OpenAI OpCo, LLC (`2DC432GLL2`), version `26.928.31416` / build `12553` | Unmodified transparent PNG from `Contents/Resources/app.asar`, `webview/assets/codex-app-ga-logo-3e5209898ca3.png`. Verified the extracted bytes against the archive's SHA-256 integrity record. Preserved the blue/purple gradient and white terminal mark; no cropping, tracing or recoloring. The shared desktop app identifies itself as `com.openai.codex`. |
| Claude | [Anthropic brand guidelines](https://github.com/anthropics/skills/blob/8a1541c4a3ffa5a20a5a91de0dcf3f0bab1d1ef4/skills/brand-guidelines/SKILL.md) | Existing bundled silhouette, replacing white with the documented primary accent `#D97757`. This is a palette-backed variant, not an unmodified logo download. |
| Antigravity | [Official homepage PNG](https://antigravity.google/assets/image/antigravity-logo.png) | Unmodified transparent PNG. Native SVG decoding flattens the homepage's blurred gradient, so use the official raster asset. |
| Mistral | [Official homepage](https://mistral.ai/) header SVG; [brand page](https://mistral.ai/brand/) | Preserved all five path fills; adjusted square viewBox for padding. |
| Muse Code / Meta | [Official developer site asset](https://dev.meta.ai/logo/meta-logo-with-text.svg) | Removed wordmark paths; retained the Meta symbol and gradients. Adjusted square viewBox for padding. |
| Bedrock | [AWS architecture icon library](https://aws.amazon.com/architecture/icons/), `Icon-package_07312026`, `Arch_Amazon-Bedrock_64.svg` | Preserved the official colored background and white glyph; expanded viewBox for transparent padding. |
| Vertex AI | [Google Cloud icon library](https://cloud.google.com/icons), `core-products-icons.zip`, `VertexAI-512-color.svg` | Unmodified vector artwork, including the original transparent padding. |
| Pi (monochrome) | [Official favicon](https://pi.dev/favicon.svg), verified 2026-10-08 | Preserved the three block paths and `560×560` viewBox; replaced the website's light/dark CSS fills with `currentColor` for adaptive template rendering. The app, website logo, and embedded CLI dashboard share the same geometry. |

Pi uses its product mark through the adaptive template fallback, including brand requests. The upstream README links the colored [website logo](https://pi.dev/logo-auto.svg), but that hosted asset is outside the MIT-licensed source tree and its redistribution terms were not established. No curated colored Pi asset is bundled.

When adding another brand, verify artwork against a primary source and document the transformation
here before enabling original rendering. Do not infer a brand color from provider progress-bar colors.

Codex provider-level icons use the app's product-specific terminal artwork. Account/source and
model child rows retain the generic OpenAI knot in the existing monochrome resource.
Colored provider icons use the app's transparent in-product artwork. Its desktop launcher icon
also contains an opaque background and is not suitable for these icons.

## Checksums

SHA-256 pins the reviewed local bytes; a later asset update should update this table and the source notes.

| File | SHA-256 |
| --- | --- |
| `Brand-ProviderIcon-codex.png` | `8e82b26c98a10e45798ce48124515720657f7735fb8d0853b3f087eaa8a6b74e` |
| `Brand-ProviderIcon-antigravity.png` | `193ba1805de11c23cd0c7a1df92aa0a886708e57350f6f7766100afe5befed73` |
| `Brand-ProviderIcon-bedrock.svg` | `6a0f3817d771064f3d4cb8687e415417c9abccb3930b049bb8c2643f787ec224` |
| `Brand-ProviderIcon-claude.svg` | `4cd39a3832c842390c21a6598dba20d4db91632a978cb34e39aa1659fe88fe5c` |
| `Brand-ProviderIcon-mistral.svg` | `13e29ba8fa7a2a01a3086b1cf6601e72fd389ffaac3139ccd95f046cc6f53524` |
| `Brand-ProviderIcon-muse.svg` | `b49f20f0738c318be02177b1823bc702c6007fe9c0ec20bba8641454cff20bd3` |
| `Brand-ProviderIcon-vertexai.svg` | `17922247f3110026fd637c531d0604c67a00c9a58a6e152030f2242b9fd48a8e` |

## Validation

`ProviderIconResourcesTests` verifies independent caches in both load orders, adaptive fallback and
actual colored pixels in decoded assets, including warm/green Antigravity pixels. Render synthetic
light/dark UI proof, including narrow windows and incomplete model history, with:

```sh
CODEXBAR_BRAND_ICON_PROOF_DIR=docs/screenshots/usage-spend-brand-icons \
  make test-fast FILTER='test_renderBrandIconScreenshots|test_renderProviderDetailPolishScreenshots'
```

The screenshot fixtures use synthetic usage data and an unrelated purple tint to reveal accidental
brand tinting. Model aggregation and monochrome child icons retain the existing provider association;
no model-to-vendor identity inference is added.

The contributor's [historical packaged application proof](https://github.com/Yuxin-Qiao/CodexBar/blob/404b28c5b1021fccbd868286ec26fc52349c9d16/docs/screenshots/usage-spend-brand-icons/native/README.md)
records the production settings window with synthetic inputs. The maintained regression path is the
component rendering suite above; no temporary application-entrypoint overlay is shipped here.
Menu and widget accent overrides continue to follow the existing palette policy.
