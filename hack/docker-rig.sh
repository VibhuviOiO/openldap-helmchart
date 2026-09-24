#!/usr/bin/env bash
set -euo pipefail
#
# docker-rig.sh - runs the StatefulSet's env and entrypoint shim on plain Docker.
# No cluster, no PVCs, no Services: it tests only what the chart generates.
#
# Usage: hack/docker-rig.sh [--replicas N] [--image TAG] [--set k=v]... [--keep]
# Needs: bash, docker, helm 3.

REPLICAS=3
IMAGE_TAG=""
KEEP=false
EXTRA_SETS=()
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NET=openldap-rig
PREFIX=rig-openldap

while [ $# -gt 0 ]; do
    case "$1" in
        --replicas) REPLICAS="$2"; shift 2 ;;
        --image) IMAGE_TAG="$2"; shift 2 ;;
        --set) EXTRA_SETS+=(--set "$2"); shift 2 ;;
        --keep) KEEP=true; shift ;;
        -h|--help) sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
command -v helm >/dev/null || { echo "helm 3 is required" >&2; exit 1; }

if [ -z "$IMAGE_TAG" ]; then
    IMAGE_TAG="$(helm show chart "$CHART_DIR" | awk '/^appVersion:/ {print $2}' | tr -d '"')"
fi

WORKDIR="$(mktemp -d)"
cleanup() {
    if [ "$KEEP" = true ]; then
        echo "keeping the rig (--keep); tear down with:"
        echo "  docker rm -f \$(docker ps -aq --filter name=${PREFIX}) ; docker network rm ${NET}"
        return
    fi
    for i in $(seq 0 $((REPLICAS - 1))); do
        docker rm -f "${PREFIX}-${i}" >/dev/null 2>&1 || true
    done
    docker network rm "$NET" >/dev/null 2>&1 || true
    rm -rf "$WORKDIR"
}
trap cleanup EXIT

echo "==> rendering the chart (${REPLICAS} replicas)"
helm template "$PREFIX" "$CHART_DIR" \
    --set auth.adminPassword=rig --set auth.replicationPassword=rig \
    --set "replicaCount=${REPLICAS}" \
    --set "image.tag=${IMAGE_TAG}" \
    "${EXTRA_SETS[@]+"${EXTRA_SETS[@]}"}" > "${WORKDIR}/render.yaml"

# Trailing newline on purpose: what `--from-file` and `echo pw > f` produce.
mkdir -p "${WORKDIR}/secrets"
printf 'rigadmin\n' > "${WORKDIR}/secrets/admin-password"
printf 'rigconfig\n' > "${WORKDIR}/secrets/config-password"
printf 'rigrepl\n' > "${WORKDIR}/secrets/replication-password"
chmod 400 "${WORKDIR}"/secrets/*

# Split the render into env + shim so the container runs exactly what Helm gave it.
python3 - "$WORKDIR" <<'PY'
import sys, yaml
work = sys.argv[1]
with open(f"{work}/render.yaml") as fh:
    docs = [d for d in yaml.safe_load_all(fh) if d]
sts = next(d for d in docs if d["kind"] == "StatefulSet")
c = sts["spec"]["template"]["spec"]["containers"][0]
with open(f"{work}/env.sh", "w") as fh:
    for e in c["env"]:
        if e.get("value") is None:
            continue
        fh.write("export %s=%s\n" % (e["name"], "'" + e["value"].replace("'", "'\\''") + "'"))
with open(f"{work}/shim.sh", "w") as fh:
    fh.write("\n".join(c["args"]) + "\n")
init = sts["spec"]["template"]["spec"].get("initContainers") or []
with open(f"{work}/init.sh", "w") as fh:
    fh.write("\n".join(init[0]["args"]) + "\n" if init else "true\n")
print("    env vars: %d, shim: %d lines, init: %d container(s)"
      % (len(c["env"]), len(c["args"][0].splitlines()), len(init)))
PY

echo "==> starting ${REPLICAS} providers from ${IMAGE_TAG}"
docker network rm "$NET" >/dev/null 2>&1 || true
docker network create "$NET" >/dev/null
for i in $(seq 0 $((REPLICAS - 1))); do
    docker rm -f "${PREFIX}-${i}" >/dev/null 2>&1 || true
    fqdn="${PREFIX}-${i}.${PREFIX}-headless.default.svc.cluster.local"

    # One volume set per replica, like volumeClaimTemplates, and empty -- which
    # is the whole point: Kubernetes mounts an empty PVC where the image ships
    # its cn=config skeleton, so the chart's seed-config initContainer has to put
    # it back. Run that exact command here or this rig would not reproduce a
    # real cluster.
    vol="${WORKDIR}/vol/${i}"
    mkdir -p "${vol}/config" "${vol}/data" "${vol}/logs"
    docker run --rm -v "${vol}/config:/config" --entrypoint /bin/bash \
        "vibhuvioio/openldap:${IMAGE_TAG}" -c "$(cat "${WORKDIR}/init.sh")" || exit 1

    docker run -d --name "${PREFIX}-${i}" --hostname "${PREFIX}-${i}" --network "$NET" \
        --network-alias "$fqdn" \
        --network-alias "${PREFIX}-${i}.${PREFIX}-headless" \
        -v "${WORKDIR}/env.sh:/etc/rig-env.sh:ro" \
        -v "${WORKDIR}/shim.sh:/etc/rig-shim.sh:ro" \
        -v "${WORKDIR}/secrets:/run/secrets:ro" \
        -v "${vol}/config:/etc/openldap/slapd.d" \
        -v "${vol}/data:/var/lib/ldap" \
        -v "${vol}/logs:/logs" \
        --entrypoint /bin/bash \
        "vibhuvioio/openldap:${IMAGE_TAG}" \
        -c 'set -a; . /etc/rig-env.sh; set +a; . /etc/rig-shim.sh' >/dev/null
done

echo "==> waiting for every node to finish initialising"
ready=0
for _ in $(seq 1 60); do
    ready=0
    for i in $(seq 0 $((REPLICAS - 1))); do
        docker exec "${PREFIX}-${i}" test -f /var/run/openldap/initialized 2>/dev/null \
            && ready=$((ready + 1))
    done
    [ "$ready" -eq "$REPLICAS" ] && break
    sleep 5
done
if [ "$ready" -ne "$REPLICAS" ]; then
    echo "FAIL: only ${ready}/${REPLICAS} nodes initialised" >&2
    for i in $(seq 0 $((REPLICAS - 1))); do
        echo "--- ${PREFIX}-${i} ---" >&2
        docker logs "${PREFIX}-${i}" 2>&1 | tail -20 >&2
    done
    exit 1
fi
echo "    all ${REPLICAS} initialised"

echo "==> each node's own healthcheck"
for i in $(seq 0 $((REPLICAS - 1))); do
    if docker exec "${PREFIX}-${i}" /usr/local/bin/scripts/healthcheck.sh auto >/dev/null 2>&1; then
        echo "    ${PREFIX}-${i}: healthy"
    else
        echo "FAIL: ${PREFIX}-${i} is unhealthy" >&2
        docker exec "${PREFIX}-${i}" /usr/local/bin/scripts/healthcheck.sh auto >&2 || true
        exit 1
    fi
done

if [ "$REPLICAS" -gt 1 ]; then
    echo "==> ldapcheck (peer list derived from REPLICATION_PEERS)"
    # LDAP_ADMIN_PASSWORD_FILE is the chart's contract; the env var is a fallback
    # for images whose ldapcheck predates file support.
    PEERS="$(docker exec "${PREFIX}-0" sh -c '. /var/run/openldap/ldap-runtime.env; printf "%s" "${REPLICATION_PEERS:-}"')"
    [ -n "$PEERS" ] || { echo "FAIL: REPLICATION_PEERS is empty on ordinal 0" >&2; exit 1; }
    echo "    peers: ${PEERS}"

    run_ldapcheck() {
        docker exec "$@" "${PREFIX}-0" /usr/local/bin/scripts/ldapcheck.sh --peers "$PEERS"
    }

    # Retry: a freshly started mesh briefly reports differing contextCSNs, which
    # ldapcheck correctly calls a failure. Convergence is eventual, so poll.
    ok=false
    for _ in $(seq 1 12); do
        if run_ldapcheck -e LDAP_ADMIN_PASSWORD= \
                -e LDAP_ADMIN_PASSWORD_FILE=/run/secrets/admin-password >/tmp/rig-ldapcheck.log 2>&1; then
            ok=true
            echo "    ldapcheck passed (credential read from the mounted Secret)"
            break
        fi
        if run_ldapcheck -e LDAP_ADMIN_PASSWORD=rigadmin >/tmp/rig-ldapcheck.log 2>&1; then
            ok=true
            echo "    ldapcheck passed (credential passed in the environment)"
            echo "    note: this image's ldapcheck does not read LDAP_ADMIN_PASSWORD_FILE yet,"
            echo "          so the chart's documented exec command needs the next image build."
            break
        fi
        sleep 5
    done
    if [ "$ok" != true ]; then
        echo "FAIL: ldapcheck reported problems" >&2
        cat /tmp/rig-ldapcheck.log >&2
        exit 1
    fi
else
    echo "==> ldapcheck (standalone: the chart disables replication)"
    if docker exec "${PREFIX}-0" /usr/local/bin/scripts/ldapcheck.sh; then
        echo "    ldapcheck passed"
    else
        echo "FAIL: ldapcheck reported problems" >&2
        exit 1
    fi
fi

# ldap_as_admin <ordinal> <tool> [args...] - strips the Secret's trailing newline,
# which `ldapsearch -y` would otherwise send verbatim and fail with err=49.
ldap_as_admin() {
    local ordinal=$1
    shift
    docker exec -i "${PREFIX}-${ordinal}" bash -c '
        printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw
        chmod 600 /tmp/pw
        exec "$@" -x -H ldap://localhost -D cn=Manager,dc=example,dc=com -y /tmp/pw
    ' -- "$@"
}

echo "==> write on ordinal 0, read from every other ordinal"
ldap_as_admin 0 ldapadd <<'LDIF'
dn: ou=Rig,dc=example,dc=com
objectClass: organizationalUnit
ou: Rig
LDIF

for i in $(seq 0 $((REPLICAS - 1))); do
    found=false
    for _ in $(seq 1 12); do
        if ldap_as_admin "$i" ldapsearch -b ou=Rig,dc=example,dc=com -s base dn 2>/dev/null \
             | grep -q '^dn:'; then
            found=true
            break
        fi
        sleep 2
    done
    if [ "$found" = true ]; then
        echo "    ${PREFIX}-${i}: converged"
    else
        echo "FAIL: ou=Rig never reached ${PREFIX}-${i}" >&2
        exit 1
    fi
done

echo
if [ "$REPLICAS" -gt 1 ]; then
    echo "PASS: the chart's entrypoint shim and environment produce a working"
    echo "      ${REPLICAS}-provider multi-provider cluster."
else
    echo "PASS: the chart's entrypoint shim and environment produce a working"
    echo "      standalone server (replication disabled for replicaCount=1)."
fi
