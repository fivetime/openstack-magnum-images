#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Acceptance gate: boot one VM from the image and make it a Kubernetes node.
#
#   hack/gate.sh <image-id> <manifest-file>
#
# The image's contract is one sentence: "a VM booted from me can become a
# Kubernetes node." This tests exactly that, and nothing else.
#
# Everything happens inside a single VM on one throwaway network:
#
#   - no load balancer, no floating IP, no router, no egress
#   - no SSH: the test runs from cloud-init user-data and reports through the
#     serial console, which `openstack console log show` reads without any
#     network path to the VM
#   - no image pulls: kubeadm uses the control-plane images baked into the
#     image, the CNI is the bridge plugin shipped in /opt/cni/bin, and the
#     workload pod runs with --image-pull-policy=Never
#
# The previous version built a real Magnum cluster. That tested Magnum, CAPO,
# Octavia and Neutron far more than it tested the image, and it rejected a good
# image twice for faults in those: once when a load balancer dropped the watch
# `kubectl rollout status` depends on, once when Octavia held a vip_port_id
# Neutron no longer had. It also churned the cloud it was testing on.
#
# Exit codes are the verdict, and they say who is at fault:
#   0  the image is good
#   1  the image is bad - it did not become a Kubernetes node
#   2  the cloud could not run the test - says nothing about the image
#
# Environment:
#   OS_CLOUD / OS_*      OpenStack auth
#   GATE_FLAVOR          flavor for the VM (default magnum-medium)
#   GATE_TIMEOUT         seconds to wait for the verdict (default 900)
#   GATE_BOOT_TIMEOUT    seconds to wait for nova to hand back ACTIVE (default 900)
#   GATE_KEEP            true to leave the VM and network for debugging
#   SKIP_GATE            true to skip entirely (no arm64 compute here)

set -Eeuo pipefail

log()     { printf '[gate] %s\n' "$*"; }
warn()    { printf '[gate] %s\n' "$*" >&2; }
die()     { printf '[gate] %s\n' "$*" >&2; exit 1; }        # image rejected
env_die() { printf '[gate] ENV: %s\n' "$*" >&2; exit 2; }   # cloud unusable

[[ $# -eq 2 ]] || env_die "usage: $0 <image-id> <manifest-file>"
IMAGE_ID=$1
MANIFEST=$2
[[ -f "$MANIFEST" ]] || env_die "no such manifest: $MANIFEST"

command -v openstack >/dev/null || env_die "the openstack client is required"
command -v jq >/dev/null        || env_die "jq is required"

m() { jq -r --arg k "$1" 'if has($k) then .[$k] else "" end' "$MANIFEST"; }
K8S=$(m k8s_version)
ARCH=$(m arch)
[[ -n "$K8S" && -n "$ARCH" ]] || env_die "manifest is missing k8s_version/arch"

GATE_FLAVOR=${GATE_FLAVOR:-magnum-medium}
GATE_TIMEOUT=${GATE_TIMEOUT:-900}
# Time for nova to hand back an ACTIVE VM. Generous on purpose: this cloud also
# runs RaaS, which refills its runner pool in batches, and a gate VM queued
# behind that refill sat in BUILD past a 300s limit. A busy cloud is not a
# failed image - and not a failed test either, just a slow one.
GATE_BOOT_TIMEOUT=${GATE_BOOT_TIMEOUT:-900}
GATE_DNS=${GATE_DNS:-192.168.4.254}
GATE_SUBNET=${GATE_SUBNET:-10.180.0.0/24}
# Used only when publishing the durable cluster template after a pass.
GATE_EXTERNAL_NET=${GATE_EXTERNAL_NET:-public}
GATE_NETWORK_DRIVER=${GATE_NETWORK_DRIVER:-calico}
GATE_LABELS=${GATE_LABELS:-"kube_tag=v${K8S},octavia_provider=ovn,octavia_lb_algorithm=SOURCE_IP_PORT"}

SUFFIX=${GITHUB_RUN_ID:-$(date +%s)}
NAME="gate-v${K8S}-${ARCH}-${SUFFIX}"
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
openstack flavor show "$GATE_FLAVOR" -c id -f value >/dev/null 2>&1 ||
    env_die "flavor ${GATE_FLAVOR} not found"
openstack image show "$IMAGE_ID" -c id -f value >/dev/null 2>&1 ||
    env_die "image ${IMAGE_ID} not found"

WORK_DIR=$(mktemp -d)
CLEAN_SERVER=false
CLEAN_SUBNET=false
CLEAN_NET=false

cleanup() {
    local status=$?
    if [[ "${GATE_KEEP:-false}" == true ]]; then
        warn "GATE_KEEP=true: leaving ${NAME} standing"
    else
        if [[ "$CLEAN_SERVER" == true ]]; then
            log "deleting server ${NAME}"
            openstack server delete "$NAME" >/dev/null 2>&1 || true
            # The subnet cannot go while the port is still attached.
            local deadline=$((SECONDS + 300))
            while ((SECONDS < deadline)); do
                openstack server show "$NAME" >/dev/null 2>&1 || break
                sleep 5
            done
        fi
        [[ "$CLEAN_SUBNET" == true ]] &&
            { openstack subnet delete "$NAME" >/dev/null 2>&1 || warn "subnet ${NAME} left behind"; }
        [[ "$CLEAN_NET" == true ]] &&
            { openstack network delete "$NAME" >/dev/null 2>&1 || warn "network ${NAME} left behind"; }
    fi
    rm -rf -- "$WORK_DIR"
    return $status
}
trap cleanup EXIT

# ------------------------------------------------------------- the test
#
# Everything this VM needs is already inside it, so the network has no router
# and needs none. Nothing below reaches outside the VM.
cat >"$WORK_DIR/user-data" <<EOF
#!/bin/bash
# Report through the serial console; the gate reads it with
# \`openstack console log show\`, which needs no network path to this VM.
exec > >(tee /dev/console) 2>&1
set -x

# A gate that says FAIL without saying why costs a full ten-minute cycle to
# learn anything. Everything needed to tell "the image is broken" from "the
# control plane was still settling" goes to the console before the verdict,
# and the sentinel stays the last line.
fail() {
    echo "=== GATE DIAGNOSTICS (step=\$1) ==="
    kubectl get nodes -o wide 2>&1 | tail -5
    kubectl get pods -A -o wide 2>&1 | tail -20
    kubectl describe pod gate 2>&1 | tail -30
    kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -20
    echo "--- CNI ---"
    ls -l /etc/cni/net.d/ 2>&1
    ip -br addr 2>&1
    echo "--- CRI images ---"
    crictl images 2>&1 | head -15
    echo "--- kubelet ---"
    journalctl -u kubelet --no-pager -n 30 2>&1
    echo "=== END DIAGNOSTICS ==="
    echo "GATE_RESULT status=FAIL step=\$1"
    exit 1
}

# The bridge plugin ships in /opt/cni/bin, so the node reaches Ready without
# pulling a CNI image. A real CNI (Calico, Cilium) would need egress, which
# would tie this verdict to the cloud's networking instead of to the image.
# Single node, so no overlay and no NetworkPolicy is needed or tested.
mkdir -p /etc/cni/net.d
#
# isDefaultGateway alone. Adding routes:[{dst:0.0.0.0/0}] to the IPAM as well
# makes both the plugin and the IPAM result carry a default route, and the
# second RTM_NEWROUTE fails:
#   failed to add route '0.0.0.0/0 via 10.244.0.1 dev eth0': file exists
# Every sandbox on the node then fails to start, coredns included.
cat > /etc/cni/net.d/10-gate-bridge.conf <<'CNI'
{"cniVersion":"1.0.0","name":"gate","type":"bridge","bridge":"cni0",
 "isDefaultGateway":true,
 "ipam":{"type":"host-local","subnet":"10.244.0.0/16"}}
CNI

# A config file rather than flags, for two reasons.
#
# timeouts: the v1beta4 defaults are kubernetesAPICall 1m and
# controlPlaneComponentHealthCheck 4m. On the 2 vCPU / 4 GB flavor a tenant
# actually uses, etcd and the API server need longer than a minute to answer,
# and kubeadm gave up with "Post .../clusterrolebindings: context deadline
# exceeded" while the static pods were still starting. That is the flavor
# being small, not the image being broken, so the budget is raised rather than
# the flavor - the gate should run on what tenants run on.
#
# imagePullPolicy: Never makes "the control-plane images really were preloaded"
# an assertion kubeadm itself enforces, at the earliest possible moment, with
# no registry reachable to hide a miss.
cat > /root/kubeadm.yaml <<'KUBEADM'
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///var/run/containerd/containerd.sock
  imagePullPolicy: Never
timeouts:
  controlPlaneComponentHealthCheck: 8m0s
  kubeletHealthCheck: 8m0s
  kubernetesAPICall: 5m0s
  etcdAPICall: 4m0s
  tlsBootstrap: 8m0s
  discovery: 5m0s
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${K8S}
networking:
  podSubnet: 10.244.0.0/16
KUBEADM

kubeadm init --config /root/kubeadm.yaml --skip-phases=addon/kube-proxy || fail kubeadm-init

export KUBECONFIG=/etc/kubernetes/admin.conf

# Single node: without removing the control-plane taint the test pod stays
# Pending forever and looks like a broken image.
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

for i in \$(seq 1 60); do
    kubectl get nodes \\
      -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' \\
      2>/dev/null | grep -q True && break
    sleep 5
done
kubectl get nodes -o wide

# The default ServiceAccount is created asynchronously by the service-account
# controller, and a pod referencing it is rejected until it exists. Creating
# the pod two seconds after the node went Ready lost that race:
#   pods "gate" is forbidden: error looking up service account default/default
# That is the control plane still settling, not a defect in the image.
for i in \$(seq 1 60); do
    kubectl -n default get serviceaccount default >/dev/null 2>&1 && break
    sleep 5
done

# --image-pull-policy=Never turns "the control-plane images really were
# preloaded" into a hard assertion instead of a directory listing.
# Retried: admission and the scheduler can both still be warming up.
for i in \$(seq 1 12); do
    kubectl run gate --image=registry.k8s.io/pause:3.10.2 --image-pull-policy=Never && break
    [ "\$i" = 12 ] && fail pod-create
    sleep 5
done
kubectl wait --for=condition=Ready pod/gate --timeout=180s || fail pod-ready

KUBELET=\$(kubelet --version | awk '{print \$2}')
NODE=\$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
POD=\$(kubectl get pod gate -o jsonpath='{.status.phase}')
CTRD=\$(containerd --version | awk '{print \$3}')

# One short line, last: the console log is size-capped, so the sentinel has to
# survive sitting at the end of a long boot.
echo "GATE_RESULT status=PASS kubelet=\${KUBELET} node_ready=\${NODE} pod=\${POD} containerd=\${CTRD}"
EOF

log "creating network ${NAME} (no router: the test needs no egress)"
openstack network create "$NAME" >/dev/null 2>&1 || env_die "cannot create network"
CLEAN_NET=true
openstack subnet create "$NAME" --network "$NAME" --subnet-range "$GATE_SUBNET" \
    --dns-nameserver "$GATE_DNS" >/dev/null 2>&1 || env_die "cannot create subnet"
CLEAN_SUBNET=true

log "booting ${NAME} from image ${IMAGE_ID}"
# --config-drive: user-data has to arrive without a metadata route.
openstack server create "$NAME" \
    --image "$IMAGE_ID" --flavor "$GATE_FLAVOR" \
    --network "$NAME" --config-drive true \
    --user-data "$WORK_DIR/user-data" >/dev/null 2>&1 || env_die "cannot boot server"
CLEAN_SERVER=true

log "waiting up to ${GATE_BOOT_TIMEOUT}s for the VM to reach ACTIVE"
deadline=$((SECONDS + GATE_BOOT_TIMEOUT)); status=
while ((SECONDS < deadline)); do
    status=$(openstack server show "$NAME" -f value -c status 2>/dev/null || echo UNKNOWN)
    [[ "$status" == ACTIVE ]] && break
    if [[ "$status" == ERROR ]]; then
        openstack server show "$NAME" -f value -c fault >&2 2>/dev/null || true
        env_die "VM went to ERROR before the image could be judged"
    fi
    sleep 10
done
[[ "$status" == ACTIVE ]] || env_die "VM did not reach ACTIVE (last: ${status})"
log "VM is ACTIVE"

# ------------------------------------------------------------- the verdict
#
# Poll the console log for the sentinel. Short-lived requests only: the last
# gate trusted a long-lived watch and reported a failure the cluster did not
# actually have.
log "waiting up to ${GATE_TIMEOUT}s for GATE_RESULT on the console"
deadline=$((SECONDS + GATE_TIMEOUT)); result=
while ((SECONDS < deadline)); do
    console=$(openstack console log show "$NAME" 2>/dev/null || true)
    result=$(grep -o 'GATE_RESULT .*' <<<"$console" | tail -1 || true)
    [[ -n "$result" ]] && break
    sleep 15
done

# Wide enough to carry the whole diagnostics block the VM prints before its
# verdict; 40 lines cut it off and left two failures unexplained.
dump_console() {
    warn "last ${GATE_CONSOLE_LINES:-120} console lines:"
    openstack console log show "$NAME" 2>/dev/null | tail -"${GATE_CONSOLE_LINES:-120}" >&2 || true
}

if [[ -z "$result" ]]; then
    dump_console
    die "the image never reported a result within ${GATE_TIMEOUT}s"
fi

log "$result"
grep -q 'status=PASS' <<<"$result" || { dump_console; die "the image did not become a Kubernetes node"; }

# The image is named for a Kubernetes version; a node running a different one
# means the wrong binaries were baked in.
reported=$(grep -o 'kubelet=[^ ]*' <<<"$result" | cut -d= -f2)
[[ "$reported" == "v${K8S}" ]] ||
    die "kubelet reports ${reported}, image claims v${K8S}"

# ------------------------------------------------------------- publish it
log "gate passed; promoting image ${IMAGE_ID}"
openstack image set --public --property boot_verified=true "$IMAGE_ID"

# Record the verdict in the manifest as well. The manifest is what travels to
# the release job, which has no way to ask Glance whether a node ever booted.
if tmp=$(mktemp) && jq '.boot_verified = true' "$MANIFEST" >"$tmp"; then
    mv -f "$tmp" "$MANIFEST"
else
    warn "could not record boot_verified in ${MANIFEST}"
fi

# A cluster template cannot be modified while a cluster references it, so the
# durable template is replaced rather than updated. When the old one is in use,
# keep it and publish a dated one beside it instead of failing.
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
    "$DURABLE_TMPL" >/dev/null ||
    warn "image promoted but template ${DURABLE_TMPL} could not be created"

log "published template ${DURABLE_TMPL} -> image ${IMAGE_ID}"
