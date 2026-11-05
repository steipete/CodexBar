---
summary: "SiliconFlow API key setup and prepaid account balance for China and international origins."
provider_id: siliconflow
provider_name: SiliconFlow
provider_source: API key for the prepaid account balance on the China (CNY) or international (USD) API.
plugin_scope: Read-only balance through the official user-info API on both engines; no inferred quota or reset.
read_when:
  - Configuring SiliconFlow
  - Debugging SiliconFlow balance
---

# SiliconFlow

Enable **SiliconFlow** in **Settings → Providers**, paste an API key, and leave the API URL on the China origin
unless the key was created on the international site. The key follows CodexBar's standard local config storage.
The CLI also accepts `SILICONFLOW_API_KEY`; a saved provider key takes precedence. A saved API URL takes
precedence over `SILICONFLOW_BASE_URL`; otherwise the environment value selects the origin.

```sh
codexbar usage --provider siliconflow --source api --json
```

Each refresh makes one non-billable bearer `GET /v1/user/info`. It never sends an inference request, imports
browser cookies, or starts a login flow. The key is sent only to these origins:

- China (default, CNY): `https://api.siliconflow.cn/v1/user/info` — console `https://cloud.siliconflow.cn`
- International (USD): `https://api.siliconflow.com/v1/user/info` — console `https://cloud.siliconflow.com`

A saved or environment origin may include a trailing `/v1`. Any other host, scheme, port, path, query, or
embedded credential is rejected before the key is sent. Amounts are shown in the origin's currency and are not
converted. The menu dashboard and API-key links follow the selected region; invalid origins do not open a dashboard or offer an API-key link.

The documented success body is:

```json
{
  "code": 20000,
  "message": "OK",
  "status": true,
  "data": {
    "balance": "0.88",
    "chargeBalance": "88.00",
    "totalBalance": "88.88",
    "status": "normal"
  }
}
```

**Balance** is `totalBalance` and is the menu-bar balance. **Purchased** is `chargeBalance`.
**Bonus** is `balance`, the non-top-up component. SiliconFlow does not return a spending limit, so
CodexBar does not invent a percentage, reset, or pace. A negative total stays visible because an account can be
overdue. Account status is shown only when it is not `normal`. Name, image, and email are ignored; the provider
docs say those fields are being removed. Missing or non-numeric amounts fail the refresh. No live account was
queried for this integration.

HTTP 401/403, and body code `30014`, ask you to check the API key. HTTP 429 uses the shared rate-limit handling.
HTTP 410 and body code `20092` say the balance query was refused and point to the console. Error messages never
include the response body. Both JavaScript engines use the same bundled plugin.

Public contract: [Retrieve user info](https://docs.siliconflow.com/en/api-reference/userinfo/get-user-info),
checked November 4, 2026. Unauthenticated requests to both origins returned HTTP 401 with code `30014` on that
date, so the route was still present. The monochrome icon preserves the symbol from SiliconFlow's
[official logo](https://siliconflow.cn/logo-new.svg), whose original fill is `#6E29F5`.
