set -euo pipefail

uv run jupyter nbconvert --stdout --to slides --execute tsptw_single.ipynb >/dev/null
