import psycopg
import matplotlib.pyplot as plt

conn = psycopg.connect("dbname=mctrot host=127.0.0.1 port=5432")
rows = conn.execute("SELECT pace_min_per_mi, length_m, hours_to_close_min FROM tsptw_multi_analytics ORDER BY pace_min_per_mi").fetchall()
conn.close()

paces      = [r[0] for r in rows]
lengths    = [r[1] for r in rows]
hours      = [r[2] for r in rows]

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8), sharex=True)

ax1.plot(paces, lengths, marker='o')
ax1.set_ylabel("Route length (m)")
ax1.set_title("TSPTW Multi-Pace Analytics")

ax2.plot(paces, hours, marker='o', color='tab:orange')
ax2.set_ylabel("Min hours to close")
ax2.set_xlabel("Pace (min/mi)")

plt.tight_layout()
plt.savefig("tsptw_multi_analytics.pdf")
print("Saved tsptw_multi_analytics.pdf")
