set -euo pipefail

# Load location nicknames from data/nicknames.json (committed, unlike the
# rest of data/; written by the nickname-interview devenv script) into the
# nicknames table. The JSON wins for any store it lists; nicknames only in
# the table are kept.

psql -h 127.0.0.1 -p 5432 -d mctrot \
  -v nicknames="$(cat "$(dirname "$0")/../data/nicknames.json")" << 'SQL'

CREATE TABLE IF NOT EXISTS nicknames (
  nationalstorenumber TEXT PRIMARY KEY,
  nickname            TEXT NOT NULL
);

INSERT INTO nicknames (nationalstorenumber, nickname)
SELECT nationalstorenumber, nickname
FROM json_to_recordset(:'nicknames'::json) AS n(nationalstorenumber TEXT, nickname TEXT)
ON CONFLICT (nationalstorenumber) DO UPDATE SET nickname = EXCLUDED.nickname;

SQL
