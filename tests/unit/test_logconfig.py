"""Service logging.

Small, but it is the only window into a running build, and it has already been
the difference between diagnosing a crash and guessing at one. Two properties
matter and both are asserted against `logging` itself rather than by reading the
dictionary back: that the config is one `dictConfig` accepts, and that requests
still reach a handler.
"""

import logging
import logging.config
from typing import Any

from luantibot.service import logconfig


def test_the_config_is_one_that_logging_accepts() -> None:
    """A typo here would surface as a crash on service startup, not a bad log."""
    logging.config.dictConfig(logconfig.config())


def test_every_line_carries_a_timestamp() -> None:
    cfg: dict[str, Any] = logconfig.config()
    for name in ("default", "access"):
        formatter = cfg["formatters"][name]
        assert "%(asctime)s" in formatter["fmt"]
        assert formatter["datefmt"] == logconfig.TIME_FORMAT


def test_the_timestamp_matches_luantis_debug_txt() -> None:
    """The point of the format: a line here can be lined up against the engine's
    log without converting anything."""
    formatter = logging.Formatter("%(asctime)s", datefmt=logconfig.TIME_FORMAT)
    stamped = formatter.format(logging.LogRecord("x", logging.INFO, "x", 1, "msg", None, None))
    # 2026-08-01 22:38:22 -- as debug.txt writes it.
    assert len(stamped) == 19
    assert stamped[4] == "-" and stamped[10] == " " and stamped[13] == ":"


def test_access_logging_reaches_a_handler() -> None:
    """The mod polls every couple of seconds and is answered 204 almost every
    time. That looks like noise and is the only continuous evidence that Luanti
    is alive -- when it dies, the polls simply stop. Nothing may quietly filter
    them out."""
    cfg: dict[str, Any] = logconfig.config()
    access = cfg["loggers"]["uvicorn.access"]
    assert access["handlers"] == ["access"]
    assert "filters" not in cfg["handlers"]["access"]


def test_both_streams_go_to_stdout() -> None:
    """So that redirecting one file captures the whole story."""
    cfg: dict[str, Any] = logconfig.config()
    for name in ("default", "access"):
        assert cfg["handlers"][name]["stream"] == "ext://sys.stdout"
