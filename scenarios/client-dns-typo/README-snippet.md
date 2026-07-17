# README integration snippet

Add this row to the **Scenarios** table (the orchestrator will place it):

| id | fault | mesh-native remediation |
| --- | --- | --- |
| `client-dns-typo` | client targets a non-resolving host, payments traffic drops to zero | none in the mesh; fix the client's target host |

Prose to add near the `noise-only` explanation:

`client-dns-typo` is the breadth-honesty control. Every fault scenario above
emits a pathological mesh signal that a catalog of threshold detectors can
match; this one is a real, total outage (100% of user-facing calls fail) that
shows up only as the *absence* of telemetry, one layer above the mesh in a
client's own config. Catalog-based tools, MeshMedic included, are expected to
score 0 here by design — no query fires on traffic that has stopped — while an
agentic investigator that reads the client's logs and Deployment spec can
root-cause it. It keeps the leaderboard honest about what a mesh-native
detector structurally cannot see.
