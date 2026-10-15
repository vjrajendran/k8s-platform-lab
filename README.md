# k8s-platform-lab

A complete Kubernetes platform from one command, built the way companies run it: **one management cluster runs Argo CD, and Argo CD installs everything else on every cluster from this Git repo** (GitOps, hub-and-spoke).

```
              this Git repo  ── the only source of truth
                    │  Argo CD pulls
                    ▼
  ┌──────────────── one AWS sandbox (all 9 instances) ─────────────────┐
  │  aws1-eks1  mgmt  EKS, 3 nodes      Argo CD + the platform basics   │
  │      │  manages over the VPC's private network                      │
  │      ├──▶ aws1-k1  apps  kubeadm    workloads + monitoring          │
  │      └──▶ aws1-k2  lab   kubeadm    break things; policies enforced │
  └─────────────────────────────────────────────────────────────────────┘
```

The clusters themselves come from [multicloud-k8s-labs](../multicloud-k8s-labs). This repo adds the platform on top.

## One-time setup

1. **Push this folder to a public GitHub repo.** Argo CD pulls from it, so it must be readable without credentials. It holds only manifests, no keys or cluster addresses.
   ```bash
   ./set-repo.sh https://github.com/<you>/k8s-platform-lab.git   # if not vjrajendran/k8s-platform-lab
   git init && git add . && git commit -m "Platform" && git branch -M main
   git remote add origin <your repo> && git push -u origin main
   ```
2. **Give the sandbox the platform's shape** in `multicloud-k8s-labs/labs.env`, next to the `AWS1_` keys. `./up.sh` checks this and tells you what's missing:
   ```bash
   AWS1_KUBEADM=2      # aws1-k1 (apps) + aws1-k2 (lab)
   AWS1_MANAGED=1      # aws1-eks1 (mgmt)
   AWS1_NODES=3        # 6 kubeadm + 3 EKS = the sandbox's 9 instances
   AWS1_CLOUD_LB=1     # LoadBalancer Services on the kubeadm clusters
   ```

## Daily use

```bash
./up.sh          # ~35 min from an empty sandbox: clusters (~20), Argo CD (~3), platform sync (~10)
./status.sh      # component × cluster grid of what Argo CD manages
./down.sh        # stops Argo CD, then tears the sandbox down (load balancers included)
```

`./up.sh --bootstrap-only` redoes only the Argo CD part. Use it if the clusters are already up, or if your IP changed and the Argo CD UI needs to allow your new one.

At the end `up.sh` prints the **Argo CD URL and admin password**, the **demo website URL**, and how to open **Grafana**.

## What gets installed

| Component | Main CRDs | mgmt | apps | lab |
|---|---|:-:|:-:|:-:|
| **Argo CD** (+ ApplicationSet) | `Application`, `ApplicationSet`, `AppProject` | ✅ | | |
| Gateway API v1.6.1 | `GatewayClass`, `Gateway`, `HTTPRoute`, `GRPCRoute`, `ReferenceGrant` | ✅ | ✅ | ✅ |
| Traefik (Gateway API + Ingress, cloud LoadBalancer) | `IngressRoute`, `Middleware`, … | ✅ | ✅ | ✅ |
| cert-manager + a lab CA (`lab-ca` ClusterIssuer) | `Certificate`, `Issuer`, `ClusterIssuer` | ✅ | ✅ | ✅ |
| metrics-server (`kubectl top`, HPA) | — | ✅ | ✅ | ✅ |
| Storage: EBS gp3 (EKS) / local-path (kubeadm), set as default | — | ✅ | ✅ | ✅ |
| kube-prometheus-stack | `ServiceMonitor`, `PodMonitor`, `PrometheusRule`, `Alertmanager` | | ✅ | ✅ |
| Kyverno | `Policy`, `ClusterPolicy`, `ValidatingPolicy`, `PolicyReport` | ✅ | ✅ | ✅ |
| Pod Security "baseline" policies | — | audit | audit | **enforce** |
| Demo app: nginx + `HTTPRoute` + HPA + PDB | — | | ✅ | |

## How it works

- **Bootstrap (`bootstrap.sh`)** does the only manual installs:
  1. Installs **Argo CD** on the hub with Helm. Its UI gets a load balancer that only your IP may reach.
  2. **Registers the clusters** as labelled Secrets (`platform=true`, `type=eks|kubeadm`, `role=mgmt|apps|lab`). Each spoke gets an `argocd-manager` ServiceAccount, created over SSH. The hub reaches the spoke's API on its **private VPC IP**; kubeadm's certificate covers it, so TLS verifies normally.
  3. Applies the **root app** (app of apps), which syncs everything in `root/`.
- **`root/`** holds the AppProjects and one **ApplicationSet per component**. Each ApplicationSet's *cluster generator* picks clusters by label and creates one Application per cluster, for example `traefik-aws1-k1`. Adding a cluster with the right labels gets it the whole platform.
- **`addons/<component>/`** holds Helm values, layered as `values.yaml` → `values-<type>.yaml` → `values-<role>.yaml`. The lab cluster's Kyverno enforce mode is just `addons/kyverno-policies/values-lab.yaml`. Some components are plain manifests instead (issuers, the gp3 StorageClass).
- **Ordering:** components can sync in any order. `SkipDryRunOnMissingResource` and retries with backoff let, for example, the ClusterIssuers wait until cert-manager's CRDs exist. `ServerSideApply` handles the very large CRDs (Prometheus, Kyverno).
- **AppProjects:**
  - `platform` may install anything anywhere.
  - `workloads` may only deploy from this repo into `web-demo`, and create no cluster-wide objects except its Namespace. That's what least privilege looks like in Argo CD.

## Try it

```bash
export KUBECONFIG=~/.kube/multicloud.yaml
kubectl --context aws1-k2 get crd | wc -l                       # all the new API types
kubectl --context aws1-k1 explain httproute.spec.rules           # their schemas
kubectl --context aws1-k2 run bad --image=nginx --privileged     # rejected: lab enforces baseline
kubectl --context aws1-k1 run bad --image=nginx --privileged     # allowed, but reported:
kubectl --context aws1-k1 get policyreports -A
kubectl --context aws1-k1 -n web-demo delete deployment web      # watch Argo CD put it back (self-heal)
kubectl --context aws1-k1 top pods -A                            # metrics-server
```

**Change something the GitOps way:** edit `addons/<component>/values.yaml`, commit and push. Argo CD applies it within 2 minutes, or straight away with "Refresh" in the UI.

**Add a component:** put a new ApplicationSet in `root/` (copy one), with its values in `addons/<name>/`, then push. Next on the learning roadmap: External Secrets, Velero, Argo Rollouts, KEDA, Trivy Operator, Chaos Mesh, Crossplane.

## Layout

```text
up.sh / bootstrap.sh / down.sh / status.sh    entry points
platform.env                                  sandbox name, repo URL (no secrets)
set-repo.sh                                   point all manifests at your repo
bootstrap/    argocd-values.yaml, root-app.yaml, spoke-access.sh (runs on each spoke)
root/         AppProjects + one ApplicationSet per component (synced by the root app)
addons/       Helm values / manifests per component
apps/         workloads (web-demo)
```

## Good to know

- **The demo and Argo CD load balancers** take 2–4 minutes after creation before their DNS names work.
- **Grafana isn't exposed.** Use `kubectl --context aws1-k1 -n monitoring port-forward svc/monitoring-grafana 3000:80`, then log in with admin / admin. That's a lab-only password; it's fine because Grafana isn't public.
- **On a TLS-inspecting VPN**, `kubectl` and the bootstrap can't reach EKS. Run `./up.sh` off the VPN. The kubeadm spokes are registered over SSH, so they're fine either way.
