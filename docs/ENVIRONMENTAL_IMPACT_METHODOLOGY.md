# Environmental Impact Methodology

The environmental footprint module in CodexBar estimates energy usage (and resulting CO2 emissions) from Large Language Model API consumption based on published life cycle assessments (LCAs) and power measurements. 

Because official APIs generally do not expose operational energy per request, we map specific model families to estimated Joules per token.

## Estimation Factors

### Anthropic Claude & Amazon Bedrock
* **Opus**: ~ 30.0 J/token
* **Sonnet**: ~ 15.0 J/token
* **Haiku**: ~ 5.0 J/token
* *Note: Claude models hosted via Google Vertex AI utilize these Anthropic estimates rather than Google's Gemini defaults.*

### Google Gemini & Vertex AI
* **Pro / Ultra**: ~ 25.0 J/token
* **Flash**: ~ 5.0 J/token
* *Reference: Based on Google methodology reports (e.g., Gemini apps prompt averaging 0.3 Wh or ~1080 J, translating to ~10-30 J/token depending on model scale).*

### Mistral AI
* **Large**: ~ 26.6 J/token (derived from Mistral's LCA on Le Chat 400-token output = 1.14g CO2e)
* **Small / Nemo / Ministral**: ~ 10.0 J/token
* **8x22B**: ~ 20.0 J/token
* **7B / 8x7B**: ~ 5.0 J/token

### OpenAI, Azure OpenAI, Codex
* **GPT-4 / o1 / o3**: ~ 25.0 J/token
* **GPT-4o-mini / GPT-3.5 / Text-Embedding**: ~ 5.0 J/token
* *Reference: Inferred from MLCommons power measurements context.*

## Fallback Behavior

To maintain the integrity of our calculations and prevent the presentation of "fabricated" data, CodexBar **does not use a universal fallback value** for unknown models. 

If any model in a provider's daily usage breakdown is unrecognized or unsupported, the *entire* environmental footprint calculation for that session or breakdown is safely suppressed (`nil`). This strict nil-propagation ensures that users only see footprint data when it can be confidently traced back to our documented estimation factors.

## Global Equivalencies

To make the energy usage relatable, the raw energy (`kWh`) is converted into tangible equivalents:
* **Joules to kWh**: 3,600,000 J = 1 kWh
* **Global Average Carbon Intensity**: 0.385 kg CO2e / kWh
* **Smartphone Charges**: ~ 75 charges / kWh
* **Kettle Boils**: ~ 10 boils / kWh
* **Car Kilometers**: 0.12 kg CO2e / km
