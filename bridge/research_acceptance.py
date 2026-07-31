#!/usr/bin/env python3
"""Live aggregate-only acceptance check for the loopback research broker."""

from __future__ import annotations

import argparse
import json

from research_broker import ResearchBroker, ResearchBrokerConfig, source_urls


def run_acceptance(searxng_url: str) -> dict[str, object]:
    broker = ResearchBroker(ResearchBrokerConfig(searxng_url=searxng_url, timeout_s=8.0))
    search = broker.web_search("Stackchan open source robot", max_results=3)
    urls = source_urls(search)
    fetch_ok = False
    fetch_chars = 0
    if urls:
        fetched = broker.web_fetch(urls[0], max_chars=1200)
        fetch_ok = bool(fetched.get("url")) and bool(fetched.get("excerpt"))
        fetch_chars = len(str(fetched.get("excerpt", "")))
    return {
        "schema": "stackchan.research-acceptance.v1",
        "search_result_count": len(search.get("results", [])),
        "search_has_public_https_url": bool(urls),
        "fetch_ok": fetch_ok,
        "fetch_chars": fetch_chars,
        "broker_audit_records": len(broker.audit),
        "pass": bool(urls) and fetch_ok and len(broker.audit) == 2,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--searxng-url", default="http://127.0.0.1:8080")
    args = parser.parse_args()
    report = run_acceptance(args.searxng_url)
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
