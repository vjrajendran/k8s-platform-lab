# Runs on a spoke's master1 (bootstrap.sh pipes it in over SSH).
# Creates the identity Argo CD uses to manage this cluster - the same thing
# "argocd cluster add" does - and prints its token.

set -euo pipefail
export KUBECONFIG=$HOME/.kube/config

kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin       # Argo CD installs CRDs and cluster-wide operators
subjects:
- kind: ServiceAccount
  name: argocd-manager
  namespace: kube-system
---
apiVersion: v1
kind: Secret
type: kubernetes.io/service-account-token
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations:
    kubernetes.io/service-account.name: argocd-manager
YAML

for _ in $(seq 1 30); do
    token=$(kubectl -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' | base64 -d)
    [[ -n $token ]] && { echo "$token"; exit 0; }
    sleep 1
done
echo "no token issued for argocd-manager" >&2
exit 1
