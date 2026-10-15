#!/usr/bin/env bash
#
# The whole platform from one command:
#   1. three clusters in one AWS sandbox, via multicloud-k8s-labs:
#        <sandbox>-eks1  mgmt (hub)   - Argo CD
#        <sandbox>-k1    apps (spoke) - workloads
#        <sandbox>-k2    lab  (spoke) - break things, policies enforced
#   2. Argo CD on the hub, both kubeadm clusters registered as spokes
#   3. Argo CD installs every platform component from this Git repo
#
#   ./up.sh                    build or update everything (~35 min from an empty sandbox)
#   ./up.sh --bootstrap-only   the clusters are already up - just redo steps 2 and 3

set -euo pipefail
cd "$(dirname "$0")"
source ./platform.env

LABS=$(cd "$LABS_DIR" 2>/dev/null && pwd) || { echo "multicloud-k8s-labs not found at $LABS_DIR (set LABS_DIR in platform.env)"; exit 1; }
SB=$SANDBOX
P=${SB^^}

# The sandbox's labs.env must describe this platform's shape - set there (not
# overridden here) so a plain ./up.sh in multicloud-k8s-labs builds the same thing
[[ -f $LABS/labs.env ]] || { echo "$LABS/labs.env not found - set up multicloud-k8s-labs first"; exit 1; }
missing=()
want() {
    local cur
    cur=$(grep -E "^${P}_$1=" "$LABS/labs.env" | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//' || true)
    [[ $cur == "$2" ]] || missing+=("${P}_$1=$2")
}
want KUBEADM 2   # aws1-k1 (apps) + aws1-k2 (lab)
want MANAGED 1   # aws1-eks1 (mgmt)
want NODES 3     # 3 EKS nodes: 6 kubeadm + 3 EKS = the sandbox's 9 instances
want CLOUD_LB 1  # LoadBalancer Services on the kubeadm clusters
if ((${#missing[@]})); then
    echo "Set these in $LABS/labs.env (next to your ${P}_ keys), then run ./up.sh again:"
    printf '    %s\n' "${missing[@]}"
    exit 1
fi

# Argo CD can only sync what's pushed
if ! git ls-remote --exit-code "$REPO_URL" "refs/heads/$REVISION" >/dev/null 2>&1; then
    echo "Can't read branch '$REVISION' of $REPO_URL."
    echo "Push this folder there first (a public repo), or point platform.env at it with ./set-repo.sh <url>."
    exit 1
fi

if [[ ${1:-} != --bootstrap-only ]]; then
    echo "▶ Step 1/3: clusters ($SB-eks1, $SB-k1, $SB-k2) via multicloud-k8s-labs"
    "$LABS/up.sh" "$SB" || true
    if [[ -e $LABS/.sandboxes/$SB/lock ]] && ! flock -n "$LABS/.sandboxes/$SB/lock" true 2>/dev/null; then
        echo
        echo "The clusters are still being built in the background. When ./status.sh in"
        echo "multicloud-k8s-labs shows $SB ready, run:  ./up.sh --bootstrap-only"
        exit 0
    fi
fi

exec ./bootstrap.sh
