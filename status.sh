#!/usr/bin/env bash
#
# What Argo CD manages, as a grid: one row per component, one column per cluster.
#   ✓ synced and healthy   ⟳ syncing / progressing   ✗ degraded or failing   · not on that cluster

set -uo pipefail
cd "$(dirname "$0")"
source ./platform.env
export KUBECONFIG=$HOME/.kube/multicloud.yaml
[[ -d $HOME/.local/bin ]] && PATH=$HOME/.local/bin:$PATH

kubectl --context "$SANDBOX-eks1" -n argocd get applications.argoproj.io -o json 2>/dev/null | python3 -I -c '
import json, sys
try:
    apps = json.load(sys.stdin)["items"]
except Exception:
    sys.exit("Argo CD is not reachable - is the platform up? (./up.sh)")

grid, clusters = {}, []
for a in apps:
    name = a["metadata"]["name"]
    comp = a["metadata"].get("labels", {}).get("component")
    if not comp:                       # e.g. the root app
        continue
    cluster = name[len(comp) + 1:]
    if cluster not in clusters:
        clusters.append(cluster)
    st = a.get("status", {})
    sync, health = st.get("sync", {}).get("status"), st.get("health", {}).get("status")
    if sync == "Synced" and health == "Healthy":
        mark = "\033[32m✓\033[0m"
    elif health in ("Degraded", "Missing") or st.get("operationState", {}).get("phase") in ("Failed", "Error"):
        mark = "\033[31m✗\033[0m"
    else:
        mark = "\033[33m⟳\033[0m"
    grid.setdefault(comp, {})[cluster] = mark

order = {"eks1": 0, "k1": 1, "k2": 2}
clusters.sort(key=lambda c: order.get(c.split("-")[-1], 9))
print("\n %-22s" % "component" + "".join(" %-11s" % c for c in clusters))
for comp in sorted(grid):
    # pad by visible width - the coloured marks carry invisible escape codes
    print(" %-22s" % comp + "".join(" " + grid[comp].get(c, "·") + " " * 10 for c in clusters))
print("\n ✓ synced+healthy   ⟳ in progress   ✗ failing   · not on that cluster")
print(" Details: Argo CD UI, or  kubectl --context '"$SANDBOX"'-eks1 -n argocd get applications")
'
