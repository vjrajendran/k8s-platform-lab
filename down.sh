#!/usr/bin/env bash
#
# Tear the platform down: stop Argo CD first, then destroy the sandbox.
#
# Order matters: multicloud-k8s-labs/down.sh deletes every LoadBalancer Service
# before Terraform runs (cloud load balancers aren't in Terraform's state). With
# Argo CD still running, self-heal would recreate them within seconds and they
# would be left behind in the account.

set -euo pipefail
cd "$(dirname "$0")"
source ./platform.env

LABS=$(cd "$LABS_DIR" && pwd)
HUB=$SANDBOX-eks1
export KUBECONFIG=$HOME/.kube/multicloud.yaml
[[ -d $HOME/.local/bin ]] && PATH=$HOME/.local/bin:$PATH

if kubectl --context "$HUB" -n argocd get deployment argocd-applicationset-controller >/dev/null 2>&1; then
    echo "Stopping Argo CD on $HUB so it can't recreate what down.sh removes..."
    kubectl --context "$HUB" -n argocd scale statefulset argocd-application-controller --replicas=0 >/dev/null
    kubectl --context "$HUB" -n argocd scale deployment argocd-applicationset-controller --replicas=0 >/dev/null
    kubectl --context "$HUB" -n argocd rollout status statefulset argocd-application-controller --timeout=2m >/dev/null || true
fi

exec "$LABS/down.sh" "$SANDBOX"
