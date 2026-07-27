"""Run the builder service.

    uv run python -m luantibot.service --db luantibot.sqlite

Binds to 127.0.0.1 by default. The mod runs on the same machine and nothing
about this API is safe to expose.

Port 8099, not 8080: Mapserver -- which you are likely running against the same
world -- listens on 8080, and the collision is silent apart from a bind error.
"""

from __future__ import annotations

import argparse
from pathlib import Path

import uvicorn

from luantibot.service.app import create_app
from luantibot.service.store import SqliteStore


def main() -> None:
    parser = argparse.ArgumentParser(prog="luantibot.service")
    parser.add_argument("--db", type=Path, default=Path("luantibot.sqlite"))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8099)
    args = parser.parse_args()

    uvicorn.run(create_app(SqliteStore(args.db)), host=args.host, port=args.port)


if __name__ == "__main__":
    main()
