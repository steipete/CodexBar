# Trae CN

Trae CN (trae.cn) is ByteDance's China-region IDE subscription. CodexBar shows the plan
credit total/usage and the monthly reset countdown.

## Sign-in (macOS)

Trae CN uses a manual cookie paste; there is no automatic browser import.

1. Log in at `www.trae.cn` in any browser.
2. Open DevTools (`Cmd-Option-I` in Chrome/Edge/Safari) → **Network** tab.
3. Filter by `api.trae.cn` and click any request (e.g. refresh the page if none appear).
4. Right-click the request → **Copy as cURL**.
5. In CodexBar → Settings → **Trae CN**, choose **Manual** and paste the whole cURL command
   into the cookie field. The full `Cookie:` header is extracted automatically; pasting only
   the header value also works.

The cookie is stored locally in UserDefaults and is only sent to `api.trae.cn`. When the
session expires (the menu shows a login-required error), repeat the steps above and paste a
fresh cookie.

## How it works

- The session cookie is exchanged for a short-lived Cloud-IDE JWT via
  `POST /cloudide/api/v3/common/GetUserToken` (cookie auth, empty body). The token is cached
  in memory until its `exp` and refreshed transparently.
- Usage is read from `POST /trae/api/v2/pay/user_current_entitlement_list`
  (`{"require_usage":true,"full_data":true}`, `Authorization: Cloud-IDE-JWT <token>`).
- `usage_summary` provides total/used credits across all credit packs; the subscription pack
  (`group_type == 0`) provides the reset date (`expire_time`, falling back to
  `next_billing_time`) and the plan label.
- Testing override: `TRAECN_API_URL` (HTTPS or bare host, normalized to HTTPS).
