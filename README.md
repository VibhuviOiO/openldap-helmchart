# openldap-helmchart

A Helm chart for running the [`vibhuvioio/openldap`](https://hub.docker.com/r/vibhuvioio/openldap)
image on Kubernetes as a multi-provider (N-way multi-master) OpenLDAP cluster.

Requires Kubernetes >= 1.24 and Helm 3.

**Why a separate repository.** The image repo builds and tests a container; this repo owns
everything about deploying it. Chart `version` is chart semver, `appVersion` is the OpenLDAP
version in the image, so the two release cadences are independent. Keep one
`docker-compose.yml` in the image repo for people who just want `docker run`; do not add
compose variants, Swarm files or Kubernetes manifests there.

| | Image repo (`openldap-docker`) | This repo (`openldap-helmchart`) |
|---|---|---|
| Versioning | Image tag = installed OpenLDAP version | `version` = chart semver, `appVersion` = OpenLDAP version |
| Consumers | `docker run`, `docker compose` | `helm install` |
| CI | build, lint, integration tests | `helm lint`, `helm template`, `kubeconform`, kind e2e |

## Install

Until the first release is published, install from a clone:

```bash
git clone https://github.com/VibhuviOiO/openldap-helmchart
cd openldap-helmchart

kubectl create namespace directory

# Create the credentials yourself; the chart never generates passwords.
kubectl -n directory create secret generic ldap-auth \
  --from-literal=admin-password="$(openssl rand -base64 24)" \
  --from-literal=config-password="$(openssl rand -base64 24)" \
  --from-literal=replication-password="$(openssl rand -base64 24)"

helm install ldap . -n directory --set auth.existingSecret=ldap-auth
```

Once `release.yml` has published to gh-pages:

```bash
helm repo add vibhuvioio https://VibhuviOiO.github.io/openldap-helmchart
helm repo update
helm install ldap vibhuvioio/openldap -n directory --set auth.existingSecret=ldap-auth
```

Generated passwords are not an option: Helm regenerates them on every upgrade, and the peers
stop sharing a bind credential the moment one changes.

`kubectl create secret --from-file` and `echo pw > file` both leave a **trailing newline**.
The image strips CR/LF before hashing the password, and so do the chart's own jobs, so either
form works — but a client you write yourself must strip it too, or binds fail with
`Invalid credentials (49)`.

Verify:

```bash
helm test ldap -n directory
```

## Architecture

A `StatefulSet`, never a `Deployment`: replication embeds pod names in `olcServerID` URLs and
`REPLICATION_PEERS`, and each pod derives `SERVER_ID` from its own ordinal. Random pod names
break provider identity on every rollout and can leave a node replicating from itself.

```
StatefulSet <release>-openldap  (replicas: N, podManagementPolicy: Parallel)
├── <release>-openldap-0   SERVER_ID=1   ─┐
├── <release>-openldap-1   SERVER_ID=2    ├─ mesh, converges on contextCSN
└── <release>-openldap-2   SERVER_ID=3   ─┘
        │
        ├── Service <release>-openldap           ClusterIP, for clients
        └── Service <release>-openldap-headless  headless, per-pod DNS + peers
```

`podManagementPolicy: Parallel` because the providers must come up together; ordinal 0 may
itself need a peer.

`replicaCount=1` is standalone: the chart forces `ENABLE_REPLICATION=false` whatever
`replication.enabled` says, and no replication password is required.

The container command derives, per pod:

```bash
ORDINAL="${HOSTNAME##*-}"
export SERVER_ID=$((ORDINAL + 1))
export REPLICATION_PEERS="<release>-openldap-{0..N-1}.<release>-openldap-headless"   # minus self
export REPLICATION_SERVER_IDS="1=ldap://…,2=ldap://…,3=ldap://…"
exec /usr/local/bin/startup.sh
```

## Storage

Three `volumeClaimTemplates` per pod: `data` (`/var/lib/ldap`), `config`
(`/etc/openldap/slapd.d`), `logs` (`/logs`).

1. Never share a PVC between replicas. LMDB is single-writer.
2. `slapd.d` must be per-pod and writable; `startup.sh` writes the whole configuration there.
3. `storageClass` needs `volumeBindingMode: WaitForFirstConsumer`, or cloud block storage can
   bind a volume in the wrong zone.
4. `data` must exceed `olcDbMaxSize`, hardcoded to 1 GiB in the image. Default is 5 GiB.
5. `fsGroup` is unnecessary: the image starts as root, chowns the volumes, then runs `slapd`
   as uid 55.

## Values

`values.yaml` is authoritative and carries the reasoning inline. The most used:

| Key | Default | Notes |
|---|---|---|
| `replicaCount` | `3` | Providers. `1` = standalone. |
| `auth.existingSecret` | `""` | Preferred over inline passwords. |
| `auth.adminPassword` / `replicationPassword` | `""` | Required when `existingSecret` is empty. |
| `ldap.domain` / `organization` | `example.com` / `Example Organization` | |
| `replication.enabled` / `startTLS` | `true` / `false` | StartTLS needs `tls.enabled`. |
| `features.memberOf` / `passwordPolicy` / `auditLog` | `false` | Overlays. |
| `features.monitoring` | `true` | `cn=Monitor` backend. |
| `tls.enabled` / `existingSecret` | `false` / `""` | Bring your own certificate. |
| `persistence.*` | data 5Gi, config 1Gi, logs 1Gi | `ReadWriteOnce`. |
| `networkPolicy.ingressFrom` | `[]` | Raw NetworkPolicy `from:` items for clients. |
| `backup.enabled` | `false` | Online LDIF export CronJob. |
| `tests.enabled` | `true` | `helm test` pod. |

## Networking

Pods get stable names — `<release>-openldap-0.<release>-openldap-headless.<ns>.svc.<clusterDomain>`
— and those are what the replication URLs use. Set `clusterDomain` if your cluster does not use
`cluster.local`.

The headless Service sets `publishNotReadyAddresses: true` so a starting provider is still
resolvable by its peers.

The client Service is a plain `ClusterIP`. A multi-provider cluster is **not** a load balancer:
writes are accepted by every node and reconciled asynchronously. Reads may go to the Service;
point writes at one provider or at a proxy you control.

`NetworkPolicy` admits 389/636 from the provider pods and from `networkPolicy.ingressFrom`.
`olcConnMaxPending` is a DoS absorber, not an authorisation control.

## Operations

```bash
# Replication status with convergence checks.
kubectl -n directory exec ldap-openldap-0 -- \
  env LDAP_ADMIN_PASSWORD_FILE=/run/secrets/admin-password \
  /usr/local/bin/scripts/ldapcheck.sh --peers

kubectl -n directory logs ldap-openldap-0
```

`ldapcheck.sh --peers` takes the list from `REPLICATION_PEERS` inside the container. The
`env LDAP_ADMIN_PASSWORD_FILE=…` is needed because `kubectl exec` does not inherit what PID 1
loaded, and this chart never puts the password in the container environment.

### Replacing a node

Deleting a pod is safe; it re-syncs. To rebuild from scratch, delete the pod and its PVCs:

```bash
kubectl -n directory delete pod ldap-openldap-2
kubectl -n directory delete pvc data-ldap-openldap-2 config-ldap-openldap-2 logs-ldap-openldap-2
```

Never rename a pod or move a PVC to a differently-named pod: `SERVER_ID` comes from the
ordinal.

### Backup

`backup.enabled=true` exports the data suffix over LDAP into a PVC. That is **online**, not a
crash-consistent snapshot: `slapcat` opens the LMDB environment directly and cannot run in a
separate Job while a provider holds the RWO volume.

For a better snapshot, run `slapcat` inside a provider. It opens the mdb environment read-only
and emits every database, including `cn=config`:

```bash
kubectl -n directory exec ldap-openldap-0 -- \
  slapcat -F /etc/openldap/slapd.d -l /logs/snapshot-$(date -u +%Y%m%dT%H%M%SZ).ldif
kubectl -n directory cp ldap-openldap-0:/logs/snapshot-*.ldif ./snapshot.ldif
```

A strictly consistent snapshot means a maintenance window. Back up the data **and**
`cn=config`: a data LDIF alone cannot rebuild a node, having no ACLs, overlays, indices or
replication configuration.

## Constraints the image imposes

- `runAsNonRoot: true` does not work — PID 1 is root so it can chown the volumes, then `slapd`
  runs as uid 55.
- Secrets are files, not environment variables; `env:` values show up in
  `kubectl describe pod`.
- `olcDbMaxSize` is not configurable (1 GiB).

## Testing

Three layers, cheapest first.

**1. `helm lint` / `helm template`**

```bash
helm lint . --set auth.adminPassword=x --set auth.replicationPassword=x
helm template t . --set auth.adminPassword=x --set auth.replicationPassword=x \
  | docker run --rm -i ghcr.io/yannh/kubeconform:v0.6.7 -strict -summary
```

The `lint` workflow renders every value permutation, validates each against the Kubernetes
schemas, shellchecks the bash embedded in the StatefulSet, CronJob and test pod, and checks
that `appVersion` names an image that exists on Docker Hub.

**2. Docker rig** — the StatefulSet's environment and entrypoint on plain Docker, no cluster.
Catches what `helm template` cannot: env values and peer URLs that only `slapd` rejects.

```bash
hack/docker-rig.sh --replicas 3
hack/docker-rig.sh --replicas 1     # standalone
```

**3. kind e2e** — installs the chart, waits for probes, writes on ordinal 0 and polls the
others, runs `helm test`, then deletes a pod and asserts it rejoins.

```bash
kind create cluster
helm install ldap . -n directory --create-namespace --set auth.existingSecret=ldap-auth
helm test ldap -n directory
```

## Layout

```
openldap-helmchart/
├── Chart.yaml
├── values.yaml
├── README.md
├── LICENSE
├── hack/docker-rig.sh             # the chart's container contract, without a cluster
├── templates/
│   ├── _helpers.tpl
│   ├── statefulset.yaml
│   ├── service-headless.yaml
│   ├── service-client.yaml
│   ├── secret.yaml
│   ├── serviceaccount.yaml
│   ├── networkpolicy.yaml
│   ├── backup-cronjob.yaml
│   ├── NOTES.txt
│   └── tests/connection.yaml      # helm test
└── .github/workflows/
    ├── lint.yml                   # helm lint + template + kubeconform + shellcheck
    ├── e2e.yml                    # kind: 3 providers, convergence, restart
    └── release.yml                # chart-releaser -> gh-pages + GitHub Release
```
