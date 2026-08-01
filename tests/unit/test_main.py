"""The service entry point.

Sixteen lines that nothing else touches, which is exactly where a wiring typo
hides: the arguments are only read on startup, and a wrong keyword is a
`TypeError` in front of a user rather than a failing test. `uvicorn.run` is
patched out, so this exercises the wiring without binding a port.
"""

from pathlib import Path
from typing import Any

import pytest

from luantibot.service import __main__ as entry


@pytest.fixture
def launched(monkeypatch: pytest.MonkeyPatch) -> dict[str, Any]:
    """Run `main()` and hand back what uvicorn would have been given."""
    captured: dict[str, Any] = {}

    def fake_run(app: Any, **kwargs: Any) -> None:
        captured["app"] = app
        captured.update(kwargs)

    monkeypatch.setattr(entry.uvicorn, "run", fake_run)
    return captured


def run(monkeypatch: pytest.MonkeyPatch, *argv: str) -> None:
    monkeypatch.setattr("sys.argv", ["luantibot.service", *argv])
    entry.main()


def test_binds_loopback_on_8099_by_default(
    monkeypatch: pytest.MonkeyPatch, launched: dict[str, Any], tmp_path: Path
) -> None:
    """Not 8080: Mapserver listens there, and the collision is silent apart from
    a bind error."""
    run(monkeypatch, "--db", str(tmp_path / "db.sqlite"))
    assert launched["host"] == "127.0.0.1"
    assert launched["port"] == 8099


def test_host_and_port_are_overridable(
    monkeypatch: pytest.MonkeyPatch, launched: dict[str, Any], tmp_path: Path
) -> None:
    run(monkeypatch, "--db", str(tmp_path / "db.sqlite"), "--host", "0.0.0.0", "--port", "9001")
    assert (launched["host"], launched["port"]) == ("0.0.0.0", 9001)


def test_the_database_is_created_where_asked(
    monkeypatch: pytest.MonkeyPatch, launched: dict[str, Any], tmp_path: Path
) -> None:
    db = tmp_path / "elsewhere.sqlite"
    run(monkeypatch, "--db", str(db))
    assert db.exists()


def test_the_timestamped_log_config_is_passed_through(
    monkeypatch: pytest.MonkeyPatch, launched: dict[str, Any], tmp_path: Path
) -> None:
    """The reason this test exists: this argument was once given a keyword the
    function did not take, and only starting the service revealed it."""
    run(monkeypatch, "--db", str(tmp_path / "db.sqlite"))
    formatters = launched["log_config"]["formatters"]
    assert "%(asctime)s" in formatters["default"]["fmt"]


def test_an_app_is_actually_built(
    monkeypatch: pytest.MonkeyPatch, launched: dict[str, Any], tmp_path: Path
) -> None:
    run(monkeypatch, "--db", str(tmp_path / "db.sqlite"))
    assert launched["app"] is not None
