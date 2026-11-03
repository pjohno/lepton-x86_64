#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read only the GSF Android ID from a profile database using host SQLite."""
from pathlib import Path
import sqlite3
import sys

path = Path(sys.argv[1]).resolve()
if not path.is_file():
    raise SystemExit(1)
try:
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=1) as connection:
        row = connection.execute("select value from main where name=?", ("android_id",)).fetchone()
    if row and str(row[0]).isdigit() and int(row[0]) > 0:
        print(row[0])
    else:
        raise SystemExit(1)
except sqlite3.Error:
    raise SystemExit(1)
