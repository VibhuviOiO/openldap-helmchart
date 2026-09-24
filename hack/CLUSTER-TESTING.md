# Cluster testing

`helm lint`, `helm template` and `kubeconform` do not install anything. Four real bugs in this
chart were found only by running it against a cluster, and all four passed every static check:

| bug | static checks said |
|---|---|
| `cn=config` volume mounted empty, Docker populates it | lint, kubeconform, Docker rig: all green |
| `readOnlyRootFilesystem` + projected service-account token → `StartError` | nothing |
| test/backup pods run as uid 65534 with the secret at `0400` → empty password, bind 53 | nothing |
| `concurrencyPolicy: Forbidden` (valid values are `Allow`, `Forbid`, `Replace`) | **kubeconform reported it Valid** |
| backup claim stays `Pending`, `--wait` times out on a `WaitForFirstConsumer` class | nothing |

Run `hack/cluster-test.sh` against a real cluster before trusting any of them.

## Prerequisites

```bash
helm version                 # helm 3
kubectl version --client     # brew install kubectl   (Docker Desktop also ships one)
docker info                  # only for the local options below
```

## Option A — k3s in Docker (no install, closest to a real cluster)

This is the one used to validate the chart. A real API server, kubelet and containerd, with its
own local-path provisioner.

```bash
docker run -d --name k3s-server --privileged \
  -p 6443:6443 \
  rancher/k3s:v1.31.4-k3s1 server \
  --disable=traefik --write-kubeconfig-mode=644 --tls-san=127.0.0.1

# kubeconfig comes out of the container; 127.0.0.1:6443 already maps to the host
until docker exec k3s-server test -f /etc/rancher/k3s/k3s.yaml; do sleep 5; done
docker exec k3s-server cat /etc/rancher/k3s/k3s.yaml > /tmp/k3s.yaml
export KUBECONFIG=/tmp/k3s.yaml

kubectl get nodes -o wide
```

Tear down:

```bash
docker rm -f k3s-server
```

## Option B — Docker Desktop Kubernetes (one click)

Settings → Kubernetes → *Enable Kubernetes* → Apply & Restart. It runs in the Docker Desktop VM
rather than nested in a container, so it is the most realistic local option.

```bash
kubectl config use-context docker-desktop
kubectl get nodes -o wide
```

## Option C — kind (reproduces the containerd 2.x failure)

Not what CI uses, and not a supported runtime for this chart. Useful as a control: it reproduces
the `slapd` OOM in a few minutes, so you can confirm a suspected image/runtime problem is real.
Note what you get:

```bash
brew install kind kubectl
kind create cluster --name local
kubectl config use-context kind-local
```

**On kind this chart does not start.** `slapd`'s anonymous RSS grows until it is OOM-killed, at
any `resources.limits.memory` (measured: 1 GiB → 1024 MiB, 2 GiB → 2042 MiB, 3 GiB → 3064 MiB,
no limit → 6.9 GiB):

```
Memory cgroup out of memory: Killed process slapd
  total-vm: 58737276 kB   anon-rss: 1044172 kB
```

The container log always stops at the same line:

```
daemon_init: ldap:/// ldaps:/// ldapi:///
```

The same image on the same kernel runs healthy at ~370 MB under plain Docker and on k3s
(containerd 1.7.23-k3s2). It fails on kind's containerd 2.2.0 and 2.3.4. That is an image or
runtime problem, not a chart problem — do not "fix" it with `resources`.

## Running the use case

```bash
# everything: 3 providers, helm test, replication, upgrade, backup, TLS, restart
KUBECONFIG=/tmp/k3s.yaml hack/cluster-test.sh --tls --restart

# focus on the TLS path
KUBECONFIG=/tmp/k3s.yaml hack/cluster-test.sh --tls --replicas 1

# a single provider, fastest signal
KUBECONFIG=/tmp/k3s.yaml hack/cluster-test.sh --replicas 1

# leave the namespace behind to poke at it
KUBECONFIG=/tmp/k3s.yaml hack/cluster-test.sh --keep
```

It mirrors `.github/workflows/e2e.yml` step for step:

1. `helm install --wait` and assert every provider is Ready
2. `helm test` — bind, search, `contextCSN` convergence
3. write on ordinal 0, poll the other ordinals
4. `ldapcheck.sh --peers`
5. `helm upgrade` in place, assert the data survived and the PDB held
6. run the backup CronJob and assert it completes
7. with `--tls`: install a second release with TLS and `disableAnonymousBind=true`, bind over `ldaps://`
8. with `--restart`: delete a provider and assert it rejoins

Exit code 0 means everything passed. On failure it dumps pod state, PVCs, events, `describe`
output and both containers' logs before exiting.

## Interpreting results

| symptom | meaning |
|---|---|
| `CrashLoopBackOff`, log stops at `daemon_init:` | the kind/containerd `slapd` bug above |
| `StartError: ... read-only file system` mounting `kube-api-access-*` | a pod with `readOnlyRootFilesystem` and a projected token; needs `automountServiceAccountToken: false` |
| `ldap_bind: Server is unwilling to perform (53) ... unauthenticated bind` | the password file read as empty; check the Secret's `defaultMode` against the pod's `runAsUser` |
| `spec.concurrencyPolicy: Unsupported value` | `Forbidden` is not a valid value; use `Forbid` |
| PVC `Pending` forever | the StorageClass needs `volumeBindingMode: WaitForFirstConsumer` |
| `--wait` times out while every pod is Ready | something Helm waits on is not Ready — most often a PVC nothing consumes. Check `kubectl get pvc`; a claim with no pod is `Pending` forever under `WaitForFirstConsumer` |
| post-install hook did not unblock the wait | hooks run *after* Helm finishes waiting; the fix has to be an ordinary resource |
