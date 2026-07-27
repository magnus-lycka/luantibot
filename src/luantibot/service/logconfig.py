"""Logging setup for the service process.

One departure from uvicorn's defaults: timestamps. The default format has none,
which makes the log impossible to line up against Luanti's `debug.txt` or a
crash report. Times are local, and match `debug.txt`'s format, because that is
what they get compared against -- the service's own job rows are UTC, and mixing
the two has already cost one debugging session.

Access logging stays on and unfiltered. The mod's `GET .../jobs/next` every
couple of seconds looks like noise, but it is the only continuous evidence that
Luanti is alive: nothing else reports in between jobs, and when Luanti dies the
polls simply stop. Quieting them would remove the signal this log exists for.
"""

from __future__ import annotations

from typing import Any

TIME_FORMAT = "%Y-%m-%d %H:%M:%S"


def config() -> dict[str, Any]:
    """A uvicorn `log_config` that timestamps every line."""
    return {
        "version": 1,
        "disable_existing_loggers": False,
        "formatters": {
            "default": {
                "()": "uvicorn.logging.DefaultFormatter",
                "fmt": "%(asctime)s %(levelprefix)s %(message)s",
                "datefmt": TIME_FORMAT,
                "use_colors": None,
            },
            "access": {
                "()": "uvicorn.logging.AccessFormatter",
                "fmt": (
                    '%(asctime)s %(levelprefix)s %(client_addr)s "%(request_line)s" %(status_code)s'
                ),
                "datefmt": TIME_FORMAT,
                "use_colors": None,
            },
        },
        "handlers": {
            "default": {
                "formatter": "default",
                "class": "logging.StreamHandler",
                "stream": "ext://sys.stdout",
            },
            "access": {
                "formatter": "access",
                "class": "logging.StreamHandler",
                "stream": "ext://sys.stdout",
            },
        },
        "loggers": {
            "uvicorn": {"handlers": ["default"], "level": "INFO", "propagate": False},
            "uvicorn.error": {"level": "INFO"},
            "uvicorn.access": {"handlers": ["access"], "level": "INFO", "propagate": False},
        },
    }
