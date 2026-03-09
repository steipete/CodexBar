#!/usr/bin/env python3
"""
CodexBar local usage API bridge (v1)

Exposes:
  GET /api/usage/summary?range=daily|weekly|monthly
  GET /api/usage/models?range=daily|weekly|monthly

Data source:
  codexbar CLI JSON output ("usage --format json --provider all")
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List
from urllib.parse import parse_qs, urlparse


def run_codexbar_usage_json(binary: str) -> List[Dict[str, Any]]:
    base = shlex.split(binary)
    cmd = base + ["usage", "--format", "json", "--provider", "all"]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError(f"codexbar usage failed ({p.returncode}): {p.stderr.strip()[:500]}")
    out = p.stdout.strip()
    if not out:
        return []
    data = json.loads(out)
    if isinstance(data, dict):
        return [data]
    if isinstance(data, list):
        return data
    return []


def _extract_numeric(d: Dict[str, Any], candidates: List[str]) -> float:
    for k in candidates:
        v = d.get(k)
        if isinstance(v, (int, float)):
            return float(v)
        if isinstance(v, str):
            try:
                return float(v)
            except ValueError:
                pass
    return 0.0


def normalize_payload(raw: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Normalize flexible provider payloads into:
      { provider, model, monthly_used, monthly_limit, weekly_used, weekly_limit, cost }
    """
    rows: List[Dict[str, Any]] = []

    for item in raw:
        provider = str(item.get("provider") or item.get("name") or item.get("id") or "unknown")

        # Some payloads might include nested usage blocks and model arrays.
        models = item.get("models") if isinstance(item.get("models"), list) else None

        if models:
            for m in models:
                if not isinstance(m, dict):
                    continue
                rows.append(
                    {
                        "provider": provider,
                        "model": str(m.get("model") or m.get("id") or "unknown"),
                        "monthly_used": _extract_numeric(m, ["monthlyUsed", "usedMonthly", "monthly_used", "used"]),
                        "monthly_limit": _extract_numeric(m, ["monthlyLimit", "limitMonthly", "monthly_limit", "limit"]),
                        "weekly_used": _extract_numeric(m, ["weeklyUsed", "usedWeekly", "weekly_used"]),
                        "weekly_limit": _extract_numeric(m, ["weeklyLimit", "limitWeekly", "weekly_limit"]),
                        "cost": _extract_numeric(m, ["cost", "costUsd", "usd_cost", "spend"]),
                    }
                )
        else:
            rows.append(
                {
                    "provider": provider,
                    "model": str(item.get("model") or "overall"),
                    "monthly_used": _extract_numeric(item, ["monthlyUsed", "usedMonthly", "monthly_used", "used"]),
                    "monthly_limit": _extract_numeric(item, ["monthlyLimit", "limitMonthly", "monthly_limit", "limit"]),
                    "weekly_used": _extract_numeric(item, ["weeklyUsed", "usedWeekly", "weekly_used"]),
                    "weekly_limit": _extract_numeric(item, ["weeklyLimit", "limitWeekly", "weekly_limit"]),
                    "cost": _extract_numeric(item, ["cost", "costUsd", "usd_cost", "spend"]),
                }
            )

    return rows


def build_summary(rows: List[Dict[str, Any]], range_name: str) -> Dict[str, Any]:
    if range_name == "weekly":
        used = sum(r.get("weekly_used", 0.0) for r in rows)
        limit = sum(r.get("weekly_limit", 0.0) for r in rows)
    else:
        # daily currently approximates from monthly until per-day timeline exists
        used = sum(r.get("monthly_used", 0.0) for r in rows)
        limit = sum(r.get("monthly_limit", 0.0) for r in rows)

    providers = {}
    for r in rows:
        p = r["provider"]
        providers[p] = providers.get(p, 0) + (r.get("weekly_used", 0.0) if range_name == "weekly" else r.get("monthly_used", 0.0))

    return {
        "range": range_name,
        "totalUsed": used,
        "totalLimit": limit,
        "utilizationPct": round((used / limit * 100.0), 2) if limit > 0 else None,
        "providerCount": len(set(r["provider"] for r in rows)),
        "modelCount": len(set((r["provider"], r["model"]) for r in rows)),
        "costUsd": round(sum(r.get("cost", 0.0) for r in rows), 4),
        "providers": [{"provider": k, "used": v} for k, v in sorted(providers.items(), key=lambda kv: kv[1], reverse=True)],
    }


def build_models(rows: List[Dict[str, Any]], range_name: str) -> Dict[str, Any]:
    usage_key = "weekly_used" if range_name == "weekly" else "monthly_used"
    limit_key = "weekly_limit" if range_name == "weekly" else "monthly_limit"

    agg: Dict[str, Dict[str, Any]] = {}
    for r in rows:
        key = f"{r['provider']}::{r['model']}"
        if key not in agg:
            agg[key] = {
                "provider": r["provider"],
                "model": r["model"],
                "used": 0.0,
                "limit": 0.0,
                "costUsd": 0.0,
            }
        agg[key]["used"] += float(r.get(usage_key, 0.0))
        agg[key]["limit"] += float(r.get(limit_key, 0.0))
        agg[key]["costUsd"] += float(r.get("cost", 0.0))

    models = list(agg.values())
    models.sort(key=lambda m: m["used"], reverse=True)
    for m in models:
        m["utilizationPct"] = round((m["used"] / m["limit"] * 100.0), 2) if m["limit"] > 0 else None
        m["costUsd"] = round(m["costUsd"], 4)

    return {
        "range": range_name,
        "count": len(models),
        "models": models,
    }


class Handler(BaseHTTPRequestHandler):
    binary = "codexbar"

    def _write_json(self, status: int, payload: Dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self) -> None:
        self._write_json(200, {"ok": True})

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        qs = parse_qs(parsed.query)
        range_name = (qs.get("range", ["monthly"])[0] or "monthly").lower()
        if range_name not in {"daily", "weekly", "monthly"}:
            range_name = "monthly"

        if parsed.path not in {"/api/usage/summary", "/api/usage/models", "/healthz"}:
            self._write_json(404, {"ok": False, "error": "not_found"})
            return

        if parsed.path == "/healthz":
            self._write_json(200, {"ok": True, "ts": datetime.now(timezone.utc).isoformat()})
            return

        try:
            raw = run_codexbar_usage_json(self.binary)
            rows = normalize_payload(raw)
            if parsed.path == "/api/usage/summary":
                data = build_summary(rows, range_name)
            else:
                data = build_models(rows, range_name)
            self._write_json(
                200,
                {
                    "ok": True,
                    "source": "codexbar-cli",
                    "range": range_name,
                    "ts": datetime.now(timezone.utc).isoformat(),
                    "data": data,
                },
            )
        except FileNotFoundError as e:
            self._write_json(500, {"ok": False, "error": "runtime_missing", "detail": str(e)})
        except Exception as e:
            self._write_json(500, {"ok": False, "error": "bridge_error", "detail": str(e)})


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--binary", default=os.environ.get("CODEXBAR_BIN", "codexbar"))
    args = ap.parse_args()

    Handler.binary = args.binary

    server = HTTPServer((args.host, args.port), Handler)
    print(f"CodexBar usage API running on http://{args.host}:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
