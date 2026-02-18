import psycopg
import json
import sys

DB = "dbname=mctrot host=127.0.0.1 port=5432"

with psycopg.connect(DB) as conn:
    with conn.cursor() as cur:
        cur.execute("SELECT nationalstorenumber, nickname FROM nicknames ORDER BY nationalstorenumber")
        rows = [{"nationalstorenumber": r[0], "nickname": r[1]} for r in cur.fetchall()]

json.dump(rows, sys.stdout, indent=2)
print()
