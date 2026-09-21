# openldap

Runs [`vibhuvioio/openldap`](https://hub.docker.com/r/vibhuvioio/openldap) on Kubernetes as a
multi-provider (N-way multi-master) OpenLDAP cluster: a StatefulSet of providers that all
accept writes and converge on `contextCSN`.

- Chart version and `appVersion` both track the OpenLDAP version in the image.
- Per-pod PersistentVolumeClaims for data, `cn=config` and logs.
- Optional TLS, `memberof`, `ppolicy`, `auditlog`, `cn=Monitor` and scheduled LDIF exports.

## Requirements

| | |
|---|---|
| Kubernetes | >= 1.24 |
| Helm | 3 |
| Storage | a StorageClass with `volumeBindingMode: WaitForFirstConsumer` |

## Install

```bash
helm repo add vibhuvioio https://VibhuviOiO.github.io/openldap-helmchart
helm repo update
```

Create the credentials first. The chart never generates passwords: Helm would regenerate them
on every upgrade, and the providers would stop sharing a replication credential.

```bash
kubectl create namespace directory

kubectl -n directory create secret generic ldap-auth \
  --from-literal=admin-password="$(openssl rand -base64 24)" \
  --from-literal=config-password="$(openssl rand -base64 24)" \
  --from-literal=replication-password="$(openssl rand -base64 24)"

helm install ldap vibhuvioio/openldap \
  --namespace directory \
  --version 1.0.0 \
  --set auth.existingSecret=ldap-auth
```

Or skip the Secret and set the passwords as values (`auth.adminPassword`,
`auth.replicationPassword`) — simpler for a lab, weaker for anything else.

Verify:

```bash
helm test ldap -n directory
```

## Connect

```bash
kubectl -n directory port-forward svc/ldap-openldap 389:389
ldapsearch -x -H ldap://localhost:389 \
  -D "cn=Manager,dc=example,dc=com" -W \
  -b "dc=example,dc=com"
```

In-cluster, use `ldap-openldap.directory.svc.cluster.local:389`, or
`ldaps://…:636` when `tls.enabled=true`.

The root DN is always `cn=Manager,<base DN>`; the image does not make it configurable.

## Configuration

### General

| Key | Default | Description |
|---|---|---|
| `replicaCount` | `3` | Number of providers. `1` runs standalone and forces replication off. |
| `clusterDomain` | `cluster.local` | Cluster DNS domain, used to build the replication URLs. |
| `nameOverride` | `""` | Override the chart name. |
| `fullnameOverride` | `""` | Override the generated resource names. |
| `image.repository` | `vibhuvioio/openldap` | Docker Hub is primary, `ghcr.io/vibhuvioio/openldap` is a mirror. |
| `image.tag` | `""` | Defaults to `appVersion`, which is the OpenLDAP version. |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | |
| `terminationGracePeriodSeconds` | `30` | Shorter values force a full database scan on the next start. |
| `podAnnotations`, `podLabels` | `{}` | |
| `nodeSelector`, `tolerations`, `affinity`, `topologySpreadConstraints` | empty | |

### Directory

| Key | Default | Description |
|---|---|---|
| `ldap.domain` | `example.com` | Becomes the base DN `dc=example,dc=com`. |
| `ldap.organization` | `Example Organization` | `o=` on the base entry. |
| `ldap.baseDn` | `""` | Empty derives it from `ldap.domain`, as the image does. |
| `auth.existingSecret` | `""` | Secret holding the passwords. Preferred. |
| `auth.adminPassword` | `""` | Required when `existingSecret` is empty. |
| `auth.configPassword` | `""` | Defaults to the admin password. |
| `auth.replicationPassword` | `""` | Required when replication is on; enables the least-privilege `cn=replicator` account. |
| `auth.secretKeys.adminPasswordKey` | `admin-password` | |
| `auth.secretKeys.configPasswordKey` | `config-password` | |
| `auth.secretKeys.replicationPasswordKey` | `replication-password` | |

### Replication

| Key | Default | Description |
|---|---|---|
| `replication.enabled` | `true` | Needs more than one replica to do anything. |
| `replication.startTLS` | `false` | StartTLS on the replication link. Needs `tls.enabled`. |
| `replication.tlsReqCert` | `demand` | `never`, `allow`, `try` or `demand`. |

### Features

| Key | Default | Description |
|---|---|---|
| `features.memberOf` | `false` | `memberof` overlay. |
| `features.passwordPolicy` | `false` | `ppolicy` overlay. |
| `features.auditLog` | `false` | `auditlog` overlay. |
| `features.monitoring` | `true` | `cn=Monitor` backend. |
| `features.disableAnonymousBind` | `false` | Probes keep working over `ldapi://` EXTERNAL. |
| `features.includeSchemas` | `cosine,inetorgperson,nis` | Comma-separated built-in schemas. |

### TLS

| Key | Default | Description |
|---|---|---|
| `tls.enabled` | `false` | |
| `tls.existingSecret` | `""` | Secret with `tls.crt` and `tls.key`. Required when enabled. |
| `tls.certPath`, `tls.keyPath` | `/etc/certs/tls.*` | |
| `tls.caPath` | `""` | |
| `tls.verifyClient` | `never` | `never`, `allow`, `try` or `demand`. |
| `tls.protocolMin` | `3.3` | `3.3` is TLS 1.2. |

### Tuning

| Key | Default | Description |
|---|---|---|
| `config.logLevel` | `""` | Image default: `16640` with replication, else `256`. |
| `config.threads` | `16` | |
| `config.passwordHash` | `{SSHA}` | |
| `config.querySizeSoft` / `querySizeHard` | `500` / `1000` | Admins and the replicator are exempt. |
| `config.connMaxPending` / `connMaxPendingAuth` | `100` / `1000` | |
| `config.readAccessSubject` | `users` | ACL subject given read access. |

### Storage

| Key | Default | Description |
|---|---|---|
| `persistence.enabled` | `true` | `false` uses `emptyDir` — data is lost on restart. |
| `persistence.storageClass` | `""` | Must use `WaitForFirstConsumer`. |
| `persistence.data.size` | `5Gi` | Must exceed `olcDbMaxSize`, hardcoded to 1 GiB in the image. |
| `persistence.config.size` | `1Gi` | `cn=config`. |
| `persistence.logs.size` | `1Gi` | |

### Networking, probes and policies

| Key | Default | Description |
|---|---|---|
| `service.type` | `ClusterIP` | |
| `service.ldapPort` / `ldapsPort` | `389` / `636` | |
| `service.annotations` | `{}` | |
| `serviceAccount.create` | `true` | |
| `serviceAccount.name`, `serviceAccount.annotations` | `""`, `{}` | |
| `podSecurityContext.runAsNonRoot` | `false` | The image starts as root to chown volumes, then `slapd` runs as uid 55. |
| `securityContext` | 6 added capabilities | |
| `resources` | 250m/256Mi → 1/1Gi | |
| `probes.startup.failureThreshold` / `periodSeconds` | `60` / `5` | The budget must stay >= the image's 300s convergence grace. |
| `probes.readiness.periodSeconds` | `10` | |
| `probes.liveness.initialDelaySeconds` / `periodSeconds` | `60` / `30` | |
| `networkPolicy.enabled` | `true` | Admit 389/636 from the providers plus `ingressFrom`. |
| `networkPolicy.ingressFrom` | `[]` | Raw NetworkPolicy `from:` items. |
| `podDisruptionBudget.enabled` | `true` | Keeps a provider up during a node drain. Ignored with one replica. |
| `podDisruptionBudget.maxUnavailable` | `1` | |
| `spreadAcrossNodes` | `true` | One provider per node. `ScheduleAnyway`, so a single-node cluster still schedules. |
| `topologySpreadConstraints` | `[]` | Overrides the default spread above. |

### Backup and tests

| Key | Default | Description |
|---|---|---|
| `backup.enabled` | `false` | CronJob writing LDIF exports to a PVC. |
| `backup.schedule` | `0 2 * * *` | |
| `backup.retentionDays` | `30` | `0` keeps every export. |
| `backup.historyLimit` | `3` | |
| `backup.activeDeadlineSeconds` | `3600` | |
| `backup.persistence.size` | `5Gi` | |
| `tests.enabled` | `true` | `helm test` pod. |
| `tests.convergenceTimeoutSeconds` | `120` | |

## Examples

**Standalone server** — no replication, no replication password:

```bash
helm install ldap vibhuvioio/openldap -n directory \
  --set replicaCount=1 \
  --set auth.adminPassword=secret
```

**With TLS and encrypted replication**:

```bash
kubectl -n directory create secret tls ldap-tls --cert=tls.crt --key=tls.key

helm install ldap vibhuvioio/openldap -n directory \
  --set auth.existingSecret=ldap-auth \
  --set tls.enabled=true --set tls.existingSecret=ldap-tls \
  --set replication.startTLS=true --set replication.tlsReqCert=demand
```

**Overlays and nightly exports**:

```bash
helm install ldap vibhuvioio/openldap -n directory \
  --set auth.existingSecret=ldap-auth \
  --set features.memberOf=true \
  --set features.passwordPolicy=true \
  --set backup.enabled=true --set backup.schedule="0 2 * * *"
```

**Reach the directory only from your app namespace**:

```yaml
# values-prod.yaml
networkPolicy:
  ingressFrom:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: my-app
```

## Operations

```bash
# Replication status and convergence.
kubectl -n directory exec ldap-openldap-0 -- \
  env LDAP_ADMIN_PASSWORD_FILE=/run/secrets/admin-password \
  /usr/local/bin/scripts/ldapcheck.sh --peers

helm upgrade ldap vibhuvioio/openldap -n directory --version 1.0.0 \
  --set auth.existingSecret=ldap-auth

helm uninstall ldap -n directory
```

`kubectl exec` does not inherit what PID 1 loaded, so pass `LDAP_ADMIN_PASSWORD_FILE`
explicitly; the chart never puts the password in the container environment.

**Replacing a node.** Deleting a pod is safe — it re-syncs from its peers. To rebuild from
scratch, delete the PVCs too:

```bash
kubectl -n directory delete pod ldap-openldap-2
kubectl -n directory delete pvc \
  data-ldap-openldap-2 config-ldap-openldap-2 logs-ldap-openldap-2
```

Never rename a pod or move a PVC to a differently-named pod: `SERVER_ID` is derived from the
pod ordinal.

**Backups.** `backup.enabled=true` exports over LDAP, which is online and therefore
consistent per entry but not across entries. For a snapshot that includes `cn=config`:

```bash
kubectl -n directory exec ldap-openldap-0 -- \
  slapcat -F /etc/openldap/slapd.d -l /logs/snapshot.ldif
```

A data-only LDIF cannot rebuild a node: it carries no ACLs, overlays, indices or replication
configuration.

## Limitations

These come from the image, not the chart, and they bound what you can run in production.

**The directory is capped at 1 GiB.** `olcDbMaxSize` is hardcoded to 1073741824 bytes
(`ldif/templates/configure-database.ldif`) and is not configurable. Size
`persistence.data` above that, but the cap itself is the ceiling: past it, writes fail.

**Not compatible with the `restricted` Pod Security Standard.** PID 1 runs as root so it can
`chown` the volumes before `slapd` drops to uid 55, so the pod needs `baseline` at most. On a
cluster that enforces `restricted` by default, install into a namespace with a `baseline`
label:

```bash
kubectl label namespace directory \
  pod-security.kubernetes.io/enforce=baseline
```

**Multi-master has no conflict resolution.** Every provider accepts writes and they converge on
`contextCSN`, but two simultaneous writes to the same attribute on different providers can
diverge silently — OpenLDAP has no merge step. Either write to one provider (the client
Service is not a write balancer) or partition your data so no two writers touch the same
attribute.

**Backups are online.** See [Operations](#operations).

**The image tag is the OpenLDAP version.** A chart release that only fixes the chart does not
change the image. `appVersion` records which OpenLDAP the chart expects, and the release
workflow refuses to publish unless that image exists on Docker Hub.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Pods never become Ready, `FAILED: initialisation has not completed` | Configuration failed; check `kubectl logs`. |
| `ENABLE_REPLICATION=true but no olcSyncRepl statements` | `replicaCount=1` with an older chart. Upgrade, or set `replication.enabled=false`. |
| Bind fails with `Invalid credentials (49)` from your own client | Your password file ended with a newline. The image strips CR/LF; strip it too. |
| `data` PVC pending forever | StorageClass uses `Immediate` binding and bound into another zone. |
| PVC smaller than 1 GiB fails at startup | `olcDbMaxSize` is hardcoded to 1 GiB. |
| Anonymous bind rejected | Expected when `features.disableAnonymousBind=true`. |
| Pod CrashLoopBackOff, log says `could not stat config file "/etc/openldap/slapd.conf"` | Chart older than 1.0.0, missing the `seed-config` init container. Upgrade. |
| PVC pending forever on a node drain | `podDisruptionBudget` cannot evict enough providers; `maxUnavailable` is 1 by design. |

## Links

- [Docker image](https://hub.docker.com/r/vibhuvioio/openldap)
- [Image source](https://github.com/VibhuviOiO/openldap-docker)
- [Chart source and issues](https://github.com/VibhuviOiO/openldap-helmchart)
- [Artifact Hub](https://artifacthub.io/packages/helm/vibhuvioio/openldap)
- [vibhuvioio.com](https://vibhuvioio.com)
