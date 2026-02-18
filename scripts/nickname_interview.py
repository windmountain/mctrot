import psycopg
import webbrowser
import urllib.parse

DB = "dbname=mctrot host=127.0.0.1 port=5432"

with psycopg.connect(DB) as conn:
    with conn.cursor() as cur:

        cur.execute("""
            CREATE TABLE IF NOT EXISTS nicknames (
                nationalstorenumber TEXT PRIMARY KEY,
                nickname            TEXT NOT NULL
            )
        """)
        conn.commit()

        cur.execute("""
            SELECT
                m.nationalstorenumber,
                m.addressline1,
                n.nickname
            FROM mcisland_mcd m
            LEFT JOIN tsp_route t ON t.mcd_id = m.ogc_fid
            LEFT JOIN nicknames n ON n.nationalstorenumber = m.nationalstorenumber
            ORDER BY t.stop_order NULLS LAST, m.ogc_fid
        """)
        locations = cur.fetchall()

    total = len(locations)
    print(f"{total} locations. Press Enter to skip, 'q' to quit.\n")

    for i, (store_num, address, existing) in enumerate(locations, start=1):
        query = urllib.parse.quote(f"{address}, New York, NY")
        webbrowser.open(f"https://www.google.com/maps/place/{query}")

        hint = f" [{existing}]" if existing else ""
        prompt = f"({i}/{total}) {address}{hint}: "
        try:
            response = input(prompt).strip()
        except (EOFError, KeyboardInterrupt):
            print("\nStopped.")
            break

        if response.lower() == 'q':
            print("Stopped.")
            break
        elif response == '':
            continue
        else:
            with conn.cursor() as cur:
                cur.execute("""
                    INSERT INTO nicknames (nationalstorenumber, nickname)
                    VALUES (%s, %s)
                    ON CONFLICT (nationalstorenumber) DO UPDATE SET nickname = EXCLUDED.nickname
                """, (store_num, response))
            conn.commit()

print("Done.")
