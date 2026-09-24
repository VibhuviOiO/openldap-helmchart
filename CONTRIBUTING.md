# Contributing

Maintainer notes for this repository. User-facing documentation is in
[`README.md`](README.md), which is the file Artifact Hub renders.

## Why this is a separate repository

The image repo builds and tests a container; this repo owns deploying it. The two release
cadences are independent and neither should pull the other's tooling in.

| | [openldap-docker](https://github.com/VibhuviOiO/openldap-docker) | this repo |
|---|---|---|
| Versioning | image tag = installed OpenLDAP version | `version` = `appVersion` = OpenLDAP version |
| Consumers | `docker run`, `docker compose` | `helm install` |
| CI | build, lint, integration tests | `helm lint`, `helm template`, `kubeconform`, k3s e2e |

Keep exactly one `docker-compose.yml` in the image repo. Do not add compose variants, Swarm
files, Kubernetes manifests or Helm charts there.

## Releasing

Chart `version` is independent semver; `appVersion` is the OpenLDAP version the chart
installs, and `image.tag` defaults to it. The git tag is `v<chart version>`.

```bash
# Chart.yaml: version: 1.0.0, appVersion: "2.6.10"
git tag v1.0.0 && git push origin v1.0.0
```

`release.yml` refuses to publish unless the tag equals `Chart.yaml` `version` **and**
`vibhuvioio/openldap:<appVersion>` exists on Docker Hub. It then packages the chart, rebuilds
`index.yaml` on `gh-pages`, and creates a GitHub Release with the `.tgz` attached.

An earlier scheme set the chart version to the OpenLDAP version with a `-N` suffix for
chart-only fixes. That does not work: Helm treats `2.6.10-1` as a prerelease, so it is hidden
from `helm search`, `helm install` without `--version` resolves to the older `2.6.10`, and
Artifact Hub keeps headlining the base version. Independent semver is why the fix in 1.0.0 is
what `helm install` now gets.

Merging to `main` does not publish; it runs `lint` and `e2e`. Only a tag releases.

### One-time setup

`gh-pages` must exist and Pages must be enabled before the first tag:

```bash
git checkout --orphan gh-pages
git rm -rf . >/dev/null 2>&1
git commit --allow-empty -m "chore: init gh-pages"
git push origin gh-pages
git checkout main
```

Settings → Pages → *Deploy from a branch*, branch `gh-pages`, folder `/`.
Settings → Actions → General → Workflow permissions must be *Read and write*.

`hack/gh-pages-index.html` is copied to `index.html` on every release, because a Helm
repository has `index.yaml`, not `index.html`, and the Pages root 404s without it.

### Registering with Artifact Hub

`gh-pages` is the repository; [Artifact Hub](https://artifacthub.io) is the registry people
search. Its **repository names are globally unique** and `openldap` was taken
(`danilonicioka/openldap`), so the repository slug is `vibhuvioio`:

| field | value |
|---|---|
| Kind | Helm charts |
| Name | `vibhuvioio` |
| URL | `https://VibhuviOiO.github.io/openldap-helmchart` |

The slug is only a publisher namespace and does not affect search. Artifact Hub matches on the
chart name and keywords, which is why the leading OpenLDAP chart appears under repositories
called `helm-openldap`, `symas-openldap`, `kubelauncher` and `nxest` alike. Keep
`name: openldap` — a search for `openldap` finds it, and `open-ldap` matches nothing.

| field | value | why it matters for search |
|---|---|---|
| `name` | `openldap` | what a search for `openldap` matches |
| `keywords` | `ldap`, `openldap`, `slapd`, … | secondary match |
| `artifacthub.io/category` | `database` | the shelf Artifact Hub browses by |
| `icon` | a square SVG or PNG | shown in results |

Verified publisher status is granted by proving ownership of `vibhuvioio.com` in the Artifact
Hub control panel.

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
It mounts one empty volume set per replica and runs the chart's own `seed-config` command, so
it reproduces the empty-PVC problem that a cluster hits. Catches what `helm template` cannot:
env values, peer URLs and volume contents that only `slapd` rejects.

```bash
hack/docker-rig.sh --replicas 3
hack/docker-rig.sh --replicas 1     # standalone
```

**3. k3s e2e** — the only layer that proves the chart installs on Kubernetes. It:

1. installs three providers and waits for the probes
2. runs `helm test` (bind, search, `contextCSN` convergence)
3. writes on ordinal 0 and polls the others
4. runs `ldapcheck.sh --peers`
5. upgrades in place and asserts the data survived
6. runs the backup CronJob and asserts the export succeeds
7. installs a standalone cluster with TLS and `disableAnonymousBind=true`, binds over `ldaps://`
8. deletes a pod and asserts it rejoins and catches up

```bash
# The same cluster CI uses. k3s, not kind: kind's containerd 2.x OOM-kills
# slapd before it listens. See hack/CLUSTER-TESTING.md.
docker run -d --name k3s --privileged \
  -p 6443:6443 -p 1389:1389 -p 1689:1689 \
  rancher/k3s:v1.31.4-k3s1 server \
  --disable=traefik --write-kubeconfig-mode=644 --tls-san=127.0.0.1
docker exec k3s cat /etc/rancher/k3s/k3s.yaml > /tmp/k3s.yaml
export KUBECONFIG=/tmp/k3s.yaml

helm install ldap . -n directory --create-namespace --set auth.existingSecret=ldap-auth
helm test ldap -n directory
```

## Design decisions worth keeping

**StatefulSet, never a Deployment.** Replication embeds pod names in `olcServerID` URLs and
`REPLICATION_PEERS`, and each pod derives `SERVER_ID` from its own ordinal. Random pod names
break provider identity on every rollout and can leave a node replicating from itself.

**`podManagementPolicy: Parallel`** because the providers must come up together; ordinal 0 may
itself need a peer.

**`replicaCount=1` forces replication off** regardless of `replication.enabled`. A
single-provider mesh is not a mesh, and the image's healthcheck fails hard when replication is
on with no `olcSyncRepl` statement — the pod would never become Ready and liveness would
restart it forever.

**Default spread across nodes, and a PodDisruptionBudget.** Three providers on one node is
not HA. The chart renders a `topologySpreadConstraints` entry with `ScheduleAnyway` unless you
supply your own, so a single-node cluster still schedules while a multi-node one spreads. The
PDB (`maxUnavailable: 1`) stops a drain from evicting every provider at once; it is skipped
with one replica, where there is nothing to protect.

**`fsGroup` on the backup Job.** The Job runs as uid 65534 and writes to a PVC. Without
`fsGroup` the kubelet does not make the volume group-writable, and the export dies with
"Permission denied" on most provisioners.

**Seed the `cn=config` volume from the image.** The image ships 9 files under
`/etc/openldap/slapd.d` (the `cn=config` skeleton). Docker copies image content into a fresh
named volume on first use; **Kubernetes does not** — a PVC is mounted empty and hides
whatever the image had at that path. Without the skeleton `slapd` exits immediately:

```
could not stat config file "/etc/openldap/slapd.conf": No such file or directory (2)
slapd stopped.
```

and the pod CrashLoopBackOffs. The `seed-config` init container copies the skeleton in,
mounting the PVC at `/config` rather than `/etc/openldap/slapd.d` so the image's own copy
stays visible as the source. It is a no-op when the volume is already populated.

**Probes are local checks.** `healthcheck.sh auto` requires `syncprov`, an `olcSyncRepl`
statement and a `contextCSN`, not a reachable peer, so one provider being down never restarts
the others. The startup probe budget (`60 × 5s = 300s`) is deliberately equal to the image's
`REPLICATION_CSN_GRACE`; a shorter budget would kill a node the healthcheck still considers
healthy.

**`volumeClaimTemplates`, one set per pod.** LMDB is single-writer; two `slapd` processes on
the same `data.mdb` corrupt the database. `slapd.d` must also be per-pod and writable, since
`startup.sh` writes the whole configuration there on first start.

**Secrets are files, not environment variables.** `env:` values show up in
`kubectl describe pod`. A password file with a trailing newline is the normal case, and
`ldapsearch -y` sends it verbatim while the image strips CR/LF, so the chart's jobs strip it
before use.

## Constraints the image imposes

- `runAsNonRoot: true` does not work — PID 1 is root so it can chown the volumes, then `slapd`
  runs as uid 55.
- `olcDbMaxSize` is not configurable (1 GiB). Size `persistence.data` accordingly.
- The data root DN is hardcoded to `cn=Manager,<base DN>`.

## Layout

```
├── Chart.yaml
├── values.yaml
├── README.md                      # user-facing; rendered by Artifact Hub
├── CONTRIBUTING.md                # this file
├── hack/
│   ├── docker-rig.sh              # the chart's container contract, without a cluster
│   └── gh-pages-index.html        # landing page copied into gh-pages
├── templates/
│   ├── _helpers.tpl
│   ├── statefulset.yaml
│   ├── service-headless.yaml
│   ├── service-client.yaml
│   ├── secret.yaml
│   ├── serviceaccount.yaml
│   ├── networkpolicy.yaml
│   ├── poddisruptionbudget.yaml
│   ├── backup-cronjob.yaml
│   ├── NOTES.txt
│   └── tests/connection.yaml      # helm test
└── .github/workflows/
    ├── lint.yml                   # helm lint + template + kubeconform + shellcheck
    ├── e2e.yml                    # kind: 3 providers, convergence, restart
    └── release.yml                # tag -> gh-pages + GitHub Release
```
