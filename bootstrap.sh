#!/usr/bin/env bash
#
# Steps 2 and 3 of ./up.sh: Argo CD on the hub, spokes registered, root app
# applied - then wait until Argo CD has synced the whole platform.
# Safe to re-run (e.g. after your IP changed, to update who may open Argo CD).

set -euo pipefail
cd "$(dirname "$0")"
source ./platform.env

ARGOCD_CHART_VERSION=10.10.5 # Argo CD v3.5

LABS=$(cd "$LABS_DIR" && pwd)
SB=$SANDBOX
HUB=$SB-eks1
SPOKES=("$SB-k1:apps" "$SB-k2:lab") # <context>:<role>
export KUBECONFIG=$HOME/.kube/multicloud.yaml
[[ -d $HOME/.local/bin ]] && PATH=$HOME/.local/bin:$PATH
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR)

hub() { kubectl --context "$HUB" "$@"; }
step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }
die() { echo "✗ $*" >&2; exit 1; }

# --- checks ------------------------------------------------------------------
grep -rqF "$REPO_URL" root/ || die "root/ doesn't point at $REPO_URL - run ./set-repo.sh $REPO_URL, commit and push"
for ctx in "$HUB" "${SPOKES[@]%%:*}"; do
    kubectl config get-contexts -o name | grep -qx "$ctx" ||
        die "no kubeconfig context $ctx - is the $SB sandbox built? (multicloud-k8s-labs ./status.sh)"
done
clusters_json=$(TF_WORKSPACE=$SB terraform -chdir="$LABS/terraform/aws" output -json clusters)

# --- Argo CD -------------------------------------------------------------------
step "Step 2/3: Argo CD on $HUB (the hub)"
my_ip=$(curl -fsS --max-time 10 https://checkip.amazonaws.com)
helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd --kube-context "$HUB" \
    --namespace argocd --create-namespace --version "$ARGOCD_CHART_VERSION" \
    --values bootstrap/argocd-values.yaml \
    --set "server.service.loadBalancerSourceRanges[0]=$my_ip/32" \
    --wait --timeout 10m >/dev/null
echo "  Argo CD installed (UI open to $my_ip only)"

# --- register the clusters (declaratively, as labelled cluster Secrets) ----------
step "Registering the clusters with Argo CD"
register() { # name server config-json labels...
    local name=$1 server=$2 config=$3
    shift 3
    {
        cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$name
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    platform: "true"
YAML
        local l
        for l in "$@"; do echo "    ${l%%=*}: ${l#*=}"; done
        cat <<YAML
stringData:
  name: $name
  server: $server
  config: '$config'
YAML
    } | hub apply -f - >/dev/null
}

# The hub manages itself through the in-cluster address
register "$HUB" https://kubernetes.default.svc '{"tlsClientConfig":{"insecure":false}}' type=eks role=mgmt
echo "  ✓ $HUB  role=mgmt (in-cluster)"

for spoke in "${SPOKES[@]}"; do
    ctx=${spoke%%:*} role=${spoke#*:}
    file=$HOME/.kube/multicloud/$ctx.yaml
    public_ip=$(awk '$1 == "server:" { sub("https://", "", $2); sub(":6443", "", $2); print $2; exit }' "$file")
    ca=$(awk '$1 == "certificate-authority-data:" { print $2; exit }' "$file")
    private_ip=$(python3 -I -c 'import json, sys; print(json.loads(sys.argv[1])[sys.argv[2]]["ips"]["master1"])' "$clusters_json" "$ctx")

    # A ServiceAccount on the spoke, made over SSH (works behind a TLS-inspecting VPN)
    token=$(ssh -i "$LABS/keys/$SB.pem" "${SSH_OPTS[@]}" "ubuntu@$public_ip" 'bash -s' <bootstrap/spoke-access.sh) ||
        die "couldn't create Argo CD's ServiceAccount on $ctx"
    [[ -n $token ]] || die "no Argo CD ServiceAccount token returned for $ctx"

    # The hub reaches the spoke over the VPC's private network - kubeadm's API
    # certificate includes the private IP, so TLS verifies normally
    register "$ctx" "https://$private_ip:6443" \
        "{\"bearerToken\":\"$token\",\"tlsClientConfig\":{\"caData\":\"$ca\"}}" type=kubeadm "role=$role"
    echo "  ✓ $ctx  role=$role  (https://$private_ip:6443)"
done

# --- root app ------------------------------------------------------------------
step "Step 3/3: root app - Argo CD installs the platform from $REPO_URL"
sed "s|__REPO_URL__|$REPO_URL|; s|__REVISION__|$REVISION|" bootstrap/root-app.yaml | hub apply -f - >/dev/null

# --- wait for everything to be synced and healthy --------------------------------
apps() {
    hub -n argocd get applications.argoproj.io \
        -o jsonpath='{range .items[*]}{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}{end}' 2>/dev/null
}
echo "  First sync takes ~10 minutes (CRDs, then operators, then their configs)."
deadline=$(($(date +%s) + 25 * 60))
last="" stable=0
while :; do
    list=$(apps)
    total=$(grep -c . <<<"$list" || true)
    good=$(awk '$2 == "Synced" && $3 == "Healthy"' <<<"$list" | grep -c . || true)
    line="  $(date +%H:%M:%S)  $good/$total applications synced and healthy"
    [[ $line != "$last" ]] && echo "$line"
    last=$line
    # done when everything is healthy and the ApplicationSets have stopped adding apps
    if ((total > 1 && good == total)); then
        stable=$((stable + 1))
        ((stable >= 3)) && break
    else
        stable=0
    fi
    if (($(date +%s) > deadline)); then
        echo
        echo "  Not everything is healthy after 25 minutes. Still waiting on:"
        awk '!($2 == "Synced" && $3 == "Healthy") { print "    " $0 }' <<<"$list"
        echo "  Open the Argo CD UI below to see why (click the app, then the red resource)."
        break
    fi
    sleep 10
done

# --- how to use it -----------------------------------------------------------------
argocd_host=$(hub -n argocd get service argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
password=$(hub -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
web_host=$(kubectl --context "$SB-k1" -n traefik get service traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

step "Platform ready"
cat <<EOF
  Argo CD      https://$argocd_host   (user admin, password $password)
               self-signed certificate - accept the browser warning. New load balancers
               need 2-4 minutes before their DNS name works.
  Web demo     http://${web_host:-<pending>}/   (on $SB-k1, through the Gateway API)
  Grafana      kubectl --context $SB-k1 -n monitoring port-forward svc/monitoring-grafana 3000:80
               then http://localhost:3000 (admin / admin). Same for $SB-k2.

  export KUBECONFIG=$KUBECONFIG
  kubectl --context $HUB -n argocd get applications      # everything Argo CD manages
  kubectl --context $SB-k2 get crd | wc -l                # all the new API types
EOF
