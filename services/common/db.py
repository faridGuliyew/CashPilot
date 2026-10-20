"""SQLite helpers. Each workspace owns its own DB file; nothing here knows about any company."""

import sqlite3
from pathlib import Path

from services.common.config import REPO_ROOT

DATA_DIR = REPO_ROOT / "data"


def open_db(path: Path, schema: str, seed) -> sqlite3.Connection:
    """Opens (and on first use creates + seeds) a workspace DB."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fresh = not path.exists()
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    if fresh:
        conn.executescript(schema)
        seed(conn)
        conn.commit()
    return conn
