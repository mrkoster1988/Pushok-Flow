#!/usr/bin/env python3
"""Select the single 21:00 Helsinki cron run, including DST transitions.

GitHub Actions cron uses UTC; we schedule both candidate UTC hours and let
this deterministic timezone-aware guard select the correct one. A delayed
GitHub scheduled run may miss the window; manual workflow_dispatch still works.
"""
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

LOCAL_TZ = ZoneInfo("Europe/Helsinki")


def is_scheduled_hour(moment: datetime) -> bool:
    if moment.tzinfo is None:
        raise ValueError("Expected timezone-aware UTC instant")
    return moment.astimezone(LOCAL_TZ).hour == 21


if __name__ == "__main__":
    raise SystemExit(0 if is_scheduled_hour(datetime.now(timezone.utc)) else 1)