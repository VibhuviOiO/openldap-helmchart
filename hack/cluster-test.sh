#!/usr/bin/env bash
set -euo pipefail
#
# cluster-test.sh - run the chart's real-cluster use case against ANY cluster.
#
# This is the same sequence as .github/workflows/e2e.yml, but it runs wherever
# your kubeconfig points: Docker Desktop's Kubernetes, k3s, kind, a cloud
# cluster. Use it to answer "does this chart actually work on Kubernetes?"
# before trusting a green helm lint.
#
# Usage:
#   hack/cluster-test.sh                          # current context
#   KUBECONFIG=/tmp/k3s.yaml hack/cluster-test.sh
#   hack/cluster-test.sh --context kind-kind --replicas 3
#   hack/cluster-test.sh --tls --restart --keep
#
# Exit code 0 means every step passed. Anything else prints pod state, events
# and container logs before it exits.
#
# Requires: bash, kubectl, helm 3, openssl (only with --tls).

NS="${NS:-ldap-test}"
RELEASE="${RELEASE:-ldap}"
REPLICAS=3
KUBECTL_CONTEXT=""
WITH_TLS=false
WITH_RESTART=false
KEEP=false
CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while [ $# -gt 0 ]; do
    case "$1" in
        --namespace) NS="$2"; shift 2 ;;
        --release) RELEASE="$2"; shift 2 ;;
        --replicas) REPLICAS="$2"; shift 2 ;;
        --context) KUBECTL_CONTEXT="$2"; shift 2 ;;
        --tls) WITH_TLS=true; shift ;;
        --restart) WITH_RESTART=true; shift ;;
        --keep) KEEP=true; shift ;;
        -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

command -v kubectl >/dev/null || { echo "kubectl is required (brew install kubectl)" >&2; exit 1; }
command -v helm >/dev/null || { echo "helm 3 is required" >&2; exit 1; }
[ -n "$KUBECTL_CONTEXT" ] && KUBECTL=(kubectl --context "$KUBECTL_CONTEXT") || KUBECTL=(kubectl)

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1"; }

admin_pw='CiAdminPassword123'
repl_pw='CiReplicationPassword123'
base='dc=example,dc=com'
admin="cn=Manager,${base}"

# Run ldapsearch/ldapadd inside a provider as the admin, using the mounted
# Secret. The trailing newline is stripped because ldapsearch sends the file
# contents verbatim while the image strips CR/LF.
in_pod() {
    local ordinal=$1
    shift
    "${KUBECTL[@]}" -n "$NS" exec -i "${RELEASE}-openldap-${ordinal}" -- bash -c '
        printf "%s" "$(cat /run/secrets/admin-password)" > /tmp/pw
        chmod 600 /tmp/pw
        exec "$@" -x -H ldap://localhost -D '"$admin"' -y /tmp/pw
    ' -- "$@"
}

dump_ns() {
    local ns=$1
    "${KUBECTL[@]}" get ns "$ns" >/dev/null 2>&1 || return 0
    echo
    echo "===== namespace ${ns} ====="
    "${KUBECTL[@]}" -n "$ns" get pods,pvc -o wide || true
    echo "---- events ----"
    "${KUBECTL[@]}" -n "$ns" get events --sort-by=.lastTimestamp 2>/dev/null | tail -20 || true
    for p in $("${KUBECTL[@]}" -n "$ns" get pods -o name 2>/dev/null); do
        echo "===== ${p} ====="
        # Readiness/last-termination detail first: OOMKilled, StartError and an
        # unreadable-secret bind all look identical from `get pods` alone.
        "${KUBECTL[@]}" -n "$ns" get "$p" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
for cs in d["status"].get("containerStatuses", []) + d["status"].get("initContainerStatuses", []):
    ls = (cs.get("lastState") or {}).get("terminated") or {}
    st = (cs.get("state") or {})
    where = next(iter(st), "-")
    print("   %-14s ready=%s restarts=%s state=%s last=%s exit=%s" % (
        cs["name"], cs.get("ready"), cs.get("restartCount"), where,
        ls.get("reason", "-"), ls.get("exitCode", "-")))
' || true
        for c in seed-config openldap check export bind; do
            out=$("${KUBECTL[@]}" -n "$ns" logs "$p" -c "$c" --tail=25 2>/dev/null || true)
            [ -n "$out" ] && { echo "--- logs ($c) ---"; echo "$out"; }
        done
    done
}

dump() {
    echo
    echo "================ diagnostics ================"
    # Both namespaces: a TLS failure happens in ${NS}-tls, and dumping only the
    # main namespace shows a healthy cluster and no explanation.
    dump_ns "$NS"
    dump_ns "${NS}-tls"
    echo "============================================"
}
on_fail() { dump; echo; echo "FAILED: ${FAIL} check(s) failed"; exit 1; }

cleanup() {
    if [ "$KEEP" = true ]; then
        echo "keeping namespace ${NS} (--keep)"
        return
    fi
    "${KUBECTL[@]}" delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "== environment =="
"${KUBECTL[@]}" cluster-info 2>&1 | head -1
"${KUBECTL[@]}" get nodes -o wide 2>&1 | tail -n +2 | awk '{print "  node:", $1, $2, $5, $NF}'
echo "  chart : $(helm show chart "$CHART_DIR" | awk '/^version:/{v=$2} /^appVersion:/{a=$2} END{print "openldap "v" (OpenLDAP "a")"}')"

echo
echo "== install (${REPLICAS} provider(s)) =="
"${KUBECTL[@]}" delete namespace "$NS" --wait=false >/dev/null 2>&1 || true
for _ in $(seq 1 30); do "${KUBECTL[@]}" get ns "$NS" >/dev/null 2>&1 || break; sleep 2; done
"${KUBECTL[@]}" create namespace "$NS" >/dev/null
"${KUBECTL[@]}" -n "$NS" create secret generic ldap-auth \
    --from-literal=admin-password="$admin_pw" \
    --from-literal=config-password="$admin_pw" \
    --from-literal=replication-password="$repl_pw" >/dev/null

set +e
helm install "$RELEASE" "$CHART_DIR" -n "$NS" \
    --set auth.existingSecret=ldap-auth \
    --set features.memberOf=true \
    --set "replicaCount=${REPLICAS}" \
    --wait --timeout 10m >/tmp/cluster-test-install.log 2>&1
install_rc=$?
set -e
if [ "$install_rc" -eq 0 ]; then
    pass "helm install --wait"
else
    fail "helm install --wait: $(tail -1 /tmp/cluster-test-install.log)"
    on_fail
fi

ready=$("${KUBECTL[@]}" -n "$NS" get statefulset "${RELEASE}-openldap" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "$ready" = "$REPLICAS" ] && pass "${ready}/${REPLICAS} providers Ready" || { fail "only ${ready}/${REPLICAS} Ready"; on_fail; }

echo
echo "== helm test =="
if helm test "$RELEASE" -n "$NS" --timeout 5m >/tmp/cluster-test-helmtests.log 2>&1; then
    pass "helm test (bind, search, contextCSN convergence)"
else
    fail "helm test: $(tail -2 /tmp/cluster-test-helmtests.log | tr '\n' ' ')"
    on_fail
fi

if [ "$REPLICAS" -gt 1 ]; then
    echo
    echo "== replication =="
    echo "dn: ou=ClusterTest,${base}
objectClass: organizationalUnit
ou: ClusterTest" | in_pod 0 ldapadd >/dev/null 2>&1 \
        && pass "write on ordinal 0" || { fail "could not write on ordinal 0"; on_fail; }

    for o in $(seq 1 $((REPLICAS - 1))); do
        ok=false
        for _ in $(seq 1 24); do
            if in_pod "$o" ldapsearch -b "ou=ClusterTest,${base}" -s base dn 2>/dev/null | grep -q '^dn:'; then
                ok=true; break
            fi
            sleep 5
        done
        [ "$ok" = true ] && pass "converged to ordinal ${o}" || { fail "ordinal ${o} never converged"; on_fail; }
    done

    if "${KUBECTL[@]}" -n "$NS" exec "${RELEASE}-openldap-0" -- \
        env LDAP_ADMIN_PASSWORD_FILE=/run/secrets/admin-password \
        /usr/local/bin/scripts/ldapcheck.sh --peers >/tmp/cluster-test-ldapcheck.log 2>&1; then
        pass "ldapcheck --peers ($(grep -c '\[PASS\]' /tmp/cluster-test-ldapcheck.log) checks)"
    else
        fail "ldapcheck --peers"
        grep -E '\[FAIL\]' /tmp/cluster-test-ldapcheck.log || true
        on_fail
    fi
fi

echo
echo "== in-place upgrade =="
if helm upgrade "$RELEASE" "$CHART_DIR" -n "$NS" \
    --set auth.existingSecret=ldap-auth --set features.memberOf=true \
    --set "replicaCount=${REPLICAS}" --set backup.enabled=true \
    --wait --timeout 10m >/tmp/cluster-test-upgrade.log 2>&1; then
    pass "helm upgrade --wait (also rolled the PDB)"
else
    fail "helm upgrade: $(tail -1 /tmp/cluster-test-upgrade.log)"; on_fail
fi

if [ "$REPLICAS" -gt 1 ]; then
    # Retry: a rolling restart can make an exec fail transiently right after
    # `helm upgrade --wait` returns, which is not data loss.
    survived=false
    for _ in $(seq 1 12); do
        if in_pod 0 ldapsearch -b "ou=ClusterTest,${base}" -s base dn 2>/dev/null | grep -q '^dn:'; then
            survived=true; break
        fi
        sleep 5
    done
    [ "$survived" = true ] && pass "data survived the upgrade" || { fail "data lost across the upgrade"; on_fail; }
fi

echo
echo "== backup CronJob =="
"${KUBECTL[@]}" -n "$NS" delete job backup-check --ignore-not-found --wait=false >/dev/null 2>&1 || true
"${KUBECTL[@]}" -n "$NS" create job backup-check --from=cronjob/"${RELEASE}-openldap-backup" >/dev/null 2>&1 || true
if "${KUBECTL[@]}" -n "$NS" wait --for=condition=complete job/backup-check --timeout=5m >/dev/null 2>&1; then
    pass "backup exports an LDIF ($("${KUBECTL[@]}" -n "$NS" logs job/backup-check 2>/dev/null | grep -o 'wrote /backup/[^ ]*' | tail -1))"
else
    fail "backup job did not complete"
    "${KUBECTL[@]}" -n "$NS" logs job/backup-check --tail=20 2>/dev/null || true
    on_fail
fi

if [ "$WITH_TLS" = true ]; then
    echo
    echo "== TLS (separate namespace) =="
    tls_ns="${NS}-tls"
    "${KUBECTL[@]}" delete namespace "$tls_ns" --wait=false >/dev/null 2>&1 || true
    # Wait for the old namespace to be GONE. `create` against one that is still
    # terminating fails with "object is being deleted", which aborts the run.
    for _ in $(seq 1 60); do
        "${KUBECTL[@]}" get ns "$tls_ns" >/dev/null 2>&1 || break
        sleep 2
    done
    "${KUBECTL[@]}" create namespace "$tls_ns" >/dev/null
    "${KUBECTL[@]}" -n "$tls_ns" create secret generic ldap-auth \
        --from-literal=admin-password="$admin_pw" --from-literal=config-password="$admin_pw" >/dev/null
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=ldap" \
        -keyout /tmp/ct-tls.key -out /tmp/ct-tls.crt 2>/dev/null
    "${KUBECTL[@]}" -n "$tls_ns" create secret tls ldap-tls --cert=/tmp/ct-tls.crt --key=/tmp/ct-tls.key >/dev/null

    if helm install "${RELEASE}-tls" "$CHART_DIR" -n "$tls_ns" \
        --set replicaCount=1 --set auth.existingSecret=ldap-auth \
        --set tls.enabled=true --set tls.existingSecret=ldap-tls \
        --set features.disableAnonymousBind=true \
        --wait --timeout 10m >/tmp/cluster-test-tls.log 2>&1; then
        pass "TLS install (probes run check_tls, anonymous bind disabled)"
        if "${KUBECTL[@]}" -n "$tls_ns" exec "${RELEASE}-tls-openldap-0" -- \
            env LDAPTLS_REQCERT=never ldapsearch -x -H ldaps://localhost:636 \
                -D "$admin" -y /run/secrets/admin-password \
                -b "$base" -s base dn 2>/dev/null | grep -q '^dn:'; then
            pass "bind over ldaps://"
        else
            fail "ldaps bind"; on_fail
        fi
    else
        fail "TLS install: $(tail -1 /tmp/cluster-test-tls.log)"; on_fail
    fi
    [ "$KEEP" = false ] && helm uninstall "${RELEASE}-tls" -n "$tls_ns" --wait >/dev/null 2>&1 || true
fi

if [ "$WITH_RESTART" = true ]; then
    echo
    echo "== provider restart =="
    last=$((REPLICAS - 1))
    "${KUBECTL[@]}" -n "$NS" delete pod "${RELEASE}-openldap-${last}" --wait=true >/dev/null 2>&1
    if "${KUBECTL[@]}" -n "$NS" wait --for=condition=Ready "pod/${RELEASE}-openldap-${last}" --timeout=5m >/dev/null 2>&1; then
        pass "deleted provider rejoined"
    else
        fail "provider did not become Ready again"; on_fail
    fi
fi

echo
echo "=============================================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "=============================================="
