#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Acceptance gate: prove a freshly built node image can carry a real
# Kubernetes cluster before any tenant can select it.
#
#   hack/gate.sh <image-id> <manifest-file>
#
# A build that merely finished is not evidence. This creates a throwaway
# cluster template and cluster from the image on the real cloud, waits for the
# control plane, checks every node reaches Ready and that a Deployment actually
# rolls out, then tears the whole thing down. Only a cluster that came up
# promotes the image to public and gets a durable cluster template.
#
# The image stays private when the gate does not run or does not pass. An
# unverified image is not published as if it were verified.
#
# Environment:
#   OS_CLOUD / OS_*      OpenStack auth (needs a project that can create clusters)
#   GATE_FLAVOR          flavor for both master and worker (default magnum-medium)
#   GATE_EXTERNAL_NET    external network (default public)
#   GATE_DNS             cluster DNS nameserver (default 192.168.4.254)
#   GATE_NETWORK_DRIVER  cilium|calico (default calico)
#   GATE_TIMEOUT         seconds to wait for CREATE_COMPLETE (default 2700)
#   GATE_KEEP            true to leave the cluster standing for debugging
#   SKIP_GATE            true to skip the cluster test (arm64 has no compute here)

set -Eeuo pipefail

log()  { printf '[gate] %s\n' "$*"; }
warn() { printf '[gate] %s\n' "$*" >&2; }
die()  { printf '[gate] %s\n' "$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <image-id> <manifest-file>"
IMAGE_ID=$1
MANIFEST=$2
[[ -f "$MANIFEST" ]] || die "no such manifest: $MANIFEST"

command -v openstack >/dev/null || die "the openstack client is required"
command -v jq >/dev/null        || die "jq is required"

m() { jq -r --arg k "$1" 'if has($k) then .[$k] else "" end' "$MANIFEST"; }
K8S=$(m k8s_version)
ARCH=$(m arch)
[[ -n "$K8S" && -n "$ARCH" ]] || die "manifest is missing k8s_version/arch"

GATE_FLAVOR=${GATE_FLAVOR:-magnum-medium}
GATE_EXTERNAL_NET=${GATE_EXTERNAL_NET:-public}
GATE_DNS=${GATE_DNS:-192.168.4.254}
GATE_NETWORK_DRIVER=${GATE_NETWORK_DRIVER:-calico}
GATE_TIMEOUT=${GATE_TIMEOUT:-2700}
# kube_tag is what the Cluster API driver reads to pick the Kubernetes version,
# so it has to agree with the binaries actually baked into the image.
# The client takes one comma-separated --labels value, not repeated --label.
GATE_LABELS=${GATE_LABELS:-"kube_tag=v${K8S},octavia_provider=ovn,octavia_lb_algorithm=SOURCE_IP_PORT"}
SUFFIX=${GITHUB_RUN_ID:-$(date +%s)}
TMPL="gate-v${K8S}-${ARCH}-${SUFFIX}"
CLUSTER="gate-v${K8S}-${ARCH}-${SUFFIX}"
DURABLE_TMPL="k8s-v${K8S}"

# ---------------------------------------------------------------- skip path
#
# There is no arm64 compute in this cloud, so an arm64 image cannot be booted
# here at all. Say so and leave the image private with boot_verified=false
# rather than pretending the gate passed.
if [[ "${SKIP_GATE:-false}" == true ]]; then
    log "SKIP: gate disabled for ${ARCH} (SKIP_GATE=true)"
    openstack image set --property boot_verified=false "$IMAGE_ID"
    log "image ${IMAGE_ID} left private, boot_verified=false"
    exit 0
fi

# ------------------------------------------------------------- preflight
#
# Check the fixtures the gate depends on before creating anything, so a
# missing flavor fails in seconds instead of after a 45 minute cluster build.
openstack flavor show "$GATE_FLAVOR" -c id -f value >/dev/null ||
    die "flavor ${GATE_FLAVOR} not found"
openstack network show "$GATE_EXTERNAL_NET" -c id -f value >/dev/null ||
    die "external network ${GATE_EXTERNAL_NET} not found"
openstack image show "$IMAGE_ID" -c id -f value >/dev/null ||
    die "image ${IMAGE_ID} not found"

WORK_DIR=$(mktemp -d)
CLEAN_CLUSTER=false
CLEAN_TMPL=false

cleanup() {
    local status=$?
    if [[ "${GATE_KEEP:-false}" == true ]]; then
        warn "GATE_KEEP=true: leaving ${CLUSTER} standing"
    else
        if [[ "$CLEAN_CLUSTER" == true ]]; then
            log "deleting cluster ${CLUSTER}"
            openstack coe cluster delete "$CLUSTER" >/dev/null 2>&1 || true
            # The template cannot be deleted while a cluster still references
            # it, so wait the cluster out before touching the template.
            local deadline=$((SECONDS + 1800))
            while ((SECONDS < deadline)); do
                openstack coe cluster show "$CLUSTER" >/dev/null 2>&1 || break
                sleep 20
            done
        fi
        if [[ "$CLEAN_TMPL" == true ]]; then
            openstack coe cluster template delete "$TMPL" >/dev/null 2>&1 ||
                warn "could not delete template ${TMPL}; remove it by hand"
        fi
    fi
    rm -rf -- "$WORK_DIR"
    return $status
}
trap cleanup EXIT

# ------------------------------------------------------------- build it
log "creating template ${TMPL} from image ${IMAGE_ID}"
# --image takes the UUID on purpose: passing a name lets the client truncate it
# at the first dot ("ubuntu-24.04-..." becomes "ubuntu-24") and the API answers
# a bare HTTP 400.
openstack coe cluster template create \
    --coe kubernetes --server-type vm \
    --image "$IMAGE_ID" \
    --flavor "$GATE_FLAVOR" --master-flavor "$GATE_FLAVOR" \
    --external-network "$GATE_EXTERNAL_NET" \
    --network-driver "$GATE_NETWORK_DRIVER" \
    --dns-nameserver "$GATE_DNS" \
    --master-lb-enabled --floating-ip-enabled \
    --labels "$GATE_LABELS" \
    "$TMPL" >/dev/null
CLEAN_TMPL=true

log "creating cluster ${CLUSTER} (1 master, 1 worker)"
openstack coe cluster create \
    --cluster-template "$TMPL" \
    --master-count 1 --node-count 1 \
    "$CLUSTER" >/dev/null
CLEAN_CLUSTER=true

log "waiting up to ${GATE_TIMEOUT}s for CREATE_COMPLETE"
deadline=$((SECONDS + GATE_TIMEOUT))
status=
while ((SECONDS < deadline)); do
    status=$(openstack coe cluster show "$CLUSTER" -f value -c status 2>/dev/null || echo UNKNOWN)
    case "$status" in
        CREATE_COMPLETE) break ;;
        CREATE_FAILED|ERROR)
            openstack coe cluster show "$CLUSTER" -f value -c status_reason || true
            die "cluster reached ${status}" ;;
    esac
    sleep 30
done
[[ "$status" == CREATE_COMPLETE ]] ||
    die "cluster did not reach CREATE_COMPLETE within ${GATE_TIMEOUT}s (last: ${status})"
log "cluster is CREATE_COMPLETE"

# ------------------------------------------------------------- prove it
export KUBECONFIG="$WORK_DIR/config"
openstack coe cluster config "$CLUSTER" --dir "$WORK_DIR" --force >/dev/null
command -v kubectl >/dev/null || die "kubectl is required to verify the cluster"

log "waiting for every node to reach Ready"
kubectl wait --for=condition=Ready nodes --all --timeout=600s ||
    { kubectl get nodes -o wide || true; die "nodes did not become Ready"; }
kubectl get nodes -o wide

# A node reporting Ready only proves the kubelet registered. Rolling out a
# Deployment additionally exercises the CRI, the CNI and the preloaded images,
# which is what the image is actually responsible for.
log "rolling out a smoke Deployment"
kubectl create deployment gate-smoke --image=registry.k8s.io/pause:3.10 --replicas=2
kubectl rollout status deployment/gate-smoke --timeout=300s ||
    { kubectl describe deployment gate-smoke || true; die "smoke Deployment did not roll out"; }
kubectl delete deployment gate-smoke --wait=false >/dev/null 2>&1 || true

# Confirm the node really runs the Kubernetes version the image claims; a
# mismatch means the wrong binaries were baked in and every later assumption
# about this image is wrong.
node_version=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
[[ "$node_version" == "v${K8S}" ]] ||
    die "kubelet reports ${node_version}, image claims v${K8S}"
log "kubelet version matches: ${node_version}"

# ------------------------------------------------------------- publish it
log "gate passed; promoting image ${IMAGE_ID}"
openstack image set --public --property boot_verified=true "$IMAGE_ID"

# A cluster template cannot be modified while a cluster references it, so the
# durable template is replaced rather than updated. When the old one is still
# in use, keep it and publish a dated one beside it instead of failing.
if openstack coe cluster template show "$DURABLE_TMPL" >/dev/null 2>&1; then
    if openstack coe cluster template delete "$DURABLE_TMPL" >/dev/null 2>&1; then
        log "replaced existing template ${DURABLE_TMPL}"
    else
        DURABLE_TMPL="k8s-v${K8S}-$(date +%Y%m%d)"
        warn "existing template is in use by a cluster; publishing ${DURABLE_TMPL} instead"
    fi
fi

openstack coe cluster template create \
    --coe kubernetes --server-type vm \
    --image "$IMAGE_ID" \
    --flavor "$GATE_FLAVOR" --master-flavor "$GATE_FLAVOR" \
    --external-network "$GATE_EXTERNAL_NET" \
    --network-driver "$GATE_NETWORK_DRIVER" \
    --dns-nameserver "$GATE_DNS" \
    --master-lb-enabled --floating-ip-enabled --public \
    --labels "$GATE_LABELS" \
    "$DURABLE_TMPL" >/dev/null

log "published template ${DURABLE_TMPL} -> image ${IMAGE_ID}"
