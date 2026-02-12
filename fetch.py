#!/usr/bin/env python3
"""Fetch data resources declared in datapackage.json.

Supports two NYC Open Data API versions:
  - SODA2 (/resource/): used for small datasets, paginated at 1000 rows
  - SODA3 (/api/v3/):   used for large datasets, requires API key from .env

Resources without an API endpoint are skipped with a note.

Usage:
    python fetch.py             # download missing files
    python fetch.py --force     # re-download everything
    python fetch.py --check     # verify hashes of existing files
"""
import base64
import hashlib
import json
import os
import sys
import urllib.request
from pathlib import Path

PACKAGE_DIR = Path(__file__).parent
DATAPACKAGE = PACKAGE_DIR / "datapackage.json"
ENV_FILE = PACKAGE_DIR / ".env"
PAGE_SIZE = 1000


def load_env():
    """Load .env file into os.environ if it exists."""
    if not ENV_FILE.exists():
        return
    with open(ENV_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key.strip(), value.strip())


def is_nyc_opendata_soda2(api_url):
    return "data.cityofnewyork.us/resource/" in api_url


def is_nyc_opendata_soda3(api_url):
    return "data.cityofnewyork.us/api/v3/" in api_url


def soda3_auth_header():
    """Build HTTP Basic auth header from .env credentials."""
    key_id = os.environ.get("NYC_OPEN_DATA_API_KEY_ID", "")
    key_secret = os.environ.get("NYC_OPEN_DATA_API_KEY_SECRET", "")
    if not key_id or not key_secret:
        return None
    encoded = base64.b64encode(f"{key_id}:{key_secret}".encode()).decode()
    return f"Basic {encoded}"


def sha256_file(filepath):
    h = hashlib.sha256()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_url(url, auth=None):
    """Fetch a URL, optionally with an auth header."""
    req = urllib.request.Request(url)
    if auth:
        req.add_header("Authorization", auth)
    with urllib.request.urlopen(req) as resp:
        return resp.read()


def soda3_to_soda2_count_url(api_url):
    """Derive a SODA2 count URL from a SODA3 endpoint.

    SODA3's $select=count(*) doesn't work as expected, so we use
    the SODA2 endpoint (no auth needed) just for the count query.
    e.g. /api/v3/views/ABC/query.geojson -> /resource/ABC.json?$select=count(*)
    """
    # Extract the dataset ID from the SODA3 URL
    # /api/v3/views/{id}/query.geojson -> {id}
    parts = api_url.split("/")
    view_idx = parts.index("views")
    dataset_id = parts[view_idx + 1]
    base = api_url.split("/api/v3/")[0]
    return f"{base}/resource/{dataset_id}.json?$select=count(*)"


def fetch_soda3_geojson(api_url, auth):
    """Fetch all features from a SODA3 GeoJSON endpoint."""
    sep = "&" if "?" in api_url else "?"

    # Get row count via SODA2 (no auth needed, reliable count)
    count_url = soda3_to_soda2_count_url(api_url)
    print(f"    counting rows...", end="", flush=True)
    data = json.loads(fetch_url(count_url))
    count = int(data[0]["count"])
    print(f" {count}")

    # Fetch all rows via SODA3 (auth required) in one request
    fetch_url_str = f"{api_url}{sep}$limit={count}"
    print(f"    downloading {count} features...", end="", flush=True)
    raw = fetch_url(fetch_url_str, auth)
    data = json.loads(raw)
    print(f" done")

    return data


def fetch_soda2_geojson(api_url):
    """Fetch all features from a SODA2 GeoJSON endpoint, paginating."""
    all_features = []
    offset = 0
    sep = "&" if "?" in api_url else "?"

    while True:
        page_url = f"{api_url}{sep}$limit={PAGE_SIZE}&$offset={offset}"
        print(f"    page at offset {offset}...", end="", flush=True)
        data = json.loads(fetch_url(page_url))

        features = data.get("features", [])
        all_features.extend(features)
        print(f" {len(features)} features")

        if len(features) < PAGE_SIZE:
            break
        offset += PAGE_SIZE

    return {"type": "FeatureCollection", "features": all_features}


def verify_hash(filepath, expected_hash):
    if not expected_hash:
        return
    expected = expected_hash.removeprefix("sha256:")
    actual = sha256_file(filepath)
    if actual == expected:
        print(f"    hash: OK")
    else:
        print(f"    hash: CHANGED (upstream data is newer than recorded)")
        print(f"      recorded: sha256:{expected}")
        print(f"      actual:   sha256:{actual}")


def fetch_resource(resource, force=False):
    name = resource["name"]
    filepath = PACKAGE_DIR / resource["path"]
    sources = resource.get("sources", [])
    api_url = sources[0].get("api") if sources else None

    if not api_url:
        hint = sources[0].get("path", sources[0].get("title", "")) if sources else ""
        if filepath.exists():
            print(f"  {name}: exists (no API endpoint — manual source)")
        else:
            print(f"  {name}: SKIP — no API endpoint, fetch manually")
            if hint:
                print(f"    source: {hint}")
        return filepath.exists()

    if filepath.exists() and not force:
        print(f"  {name}: exists (use --force to re-download)")
        verify_hash(filepath, resource.get("hash"))
        return True

    filepath.parent.mkdir(parents=True, exist_ok=True)
    print(f"  {name}: downloading from {api_url}")

    try:
        if is_nyc_opendata_soda3(api_url):
            auth = soda3_auth_header()
            if not auth:
                print(f"    FAILED — SODA3 endpoint requires API key in .env")
                return False
            data = fetch_soda3_geojson(api_url, auth)
        elif is_nyc_opendata_soda2(api_url):
            data = fetch_soda2_geojson(api_url)
        else:
            # Direct download (e.g., CUGIR)
            print(f"    downloading...", end="", flush=True)
            raw = fetch_url(api_url)
            with open(filepath, "wb") as f:
                f.write(raw)
            print(f" done")
            verify_hash(filepath, resource.get("hash"))
            return True
    except Exception as e:
        print(f"    FAILED — {e}")
        return False

    with open(filepath, "w") as f:
        json.dump(data, f)

    count = len(data.get("features", []))
    print(f"    wrote {count} features to {resource['path']}")
    verify_hash(filepath, resource.get("hash"))
    return True


def collect_hash_changes(resources):
    """Compare actual file hashes to recorded hashes in datapackage.json."""
    changes = []
    for r in resources:
        filepath = PACKAGE_DIR / r["path"]
        if not filepath.exists():
            continue
        actual = f"sha256:{sha256_file(filepath)}"
        recorded = r.get("hash", "")
        if recorded and actual == recorded:
            continue
        changes.append((r["name"], recorded or None, actual))
    return changes


def print_hash_summary(changes):
    """Print hash changes needed in datapackage.json."""
    if not changes:
        print("\nAll hashes in datapackage.json are up to date.")
        return
    print(f"\nHash updates for datapackage.json:")
    for name, old, new in changes:
        if old:
            print(f"  {name}:")
            print(f"    - {old}")
            print(f"    + {new}")
        else:
            print(f"  {name}: (no hash recorded)")
            print(f"    + {new}")


def check_only(resources):
    for r in resources:
        name = r["name"]
        filepath = PACKAGE_DIR / r["path"]
        if not filepath.exists():
            print(f"  {name}: MISSING")
            continue
        expected = r.get("hash")
        if not expected:
            print(f"  {name}: no hash recorded")
            continue
        actual = sha256_file(filepath)
        if actual == expected.removeprefix("sha256:"):
            print(f"  {name}: OK")
        else:
            print(f"  {name}: CHANGED")


def main():
    load_env()

    with open(DATAPACKAGE) as f:
        package = json.load(f)

    resources = package["resources"]
    force = "--force" in sys.argv

    print(f"{package['title']}")
    print(f"{len(resources)} resources\n")

    if "--check" in sys.argv:
        check_only(resources)
        print_hash_summary(collect_hash_changes(resources))
        return

    ok = 0
    skipped = 0
    for r in resources:
        if fetch_resource(r, force=force):
            ok += 1
        else:
            skipped += 1

    print(f"\nDone: {ok} OK, {skipped} need manual action")
    print_hash_summary(collect_hash_changes(resources))


if __name__ == "__main__":
    main()
