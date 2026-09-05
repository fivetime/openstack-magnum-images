#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Inspect a freshly built raw image and write its manifest.
#
#   hack/verify-image.sh <raw-file> <manifest-out> <os_name> <os_version> <k8s> <arch>
#
# The manifest is the contract between the build stage and the upload stage:
# the uploader publishes Glance properties from what is recorded here and never
# guesses. So every claim in it is read out of the built filesystem, not out of
# the variables the build was asked to use. A build that installed the wrong
# kubelet must not be able to describe itself as correct.
#
# Must run as root (loop mount).

set -Eeuo pipefail

log()  { printf '[verify] %s\n' "$*"; }
die()  { printf '[verify] %s\n' "$*" >&2; exit 1; }

[[ $# -eq 6 ]] || die "usage: $0 <raw> <manifest-out> <os_name> <os_version> <k8s> <arch>"
RAW=$1; OUT=$2; OS_NAME=$3; OS_VERSION=$4; K8S=$5; ARCH=$6
[[ -f "$RAW" ]] || die "no such image: $RAW"
[[ $EUID -eq 0 ]] || die "run as root"
command -v jq >/dev/null || die "jq is required"

MNT=$(mktemp -d)
LOOP=

cleanup() {
    local status=$?
    mountpoint -q "$MNT" && umount "$MNT" || true
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null || true
    rmdir "$MNT" 2>/dev/null || true
    return $status
}
trap cleanup EXIT

LOOP=$(losetup --find --show -P "$RAW")

# The layout is block-device-kubernetes: an ESP, a BIOS boot partition and an
# ext4 root. Probe for the one carrying /sbin/init rather than assuming p3.
root_part=
for part in "$LOOP"p*; do
    [[ -b "$part" ]] || continue
    [[ "$(blkid -o value -s TYPE "$part" 2>/dev/null)" == ext4 ]] || continue
    mount -o ro "$part" "$MNT"
    if [[ -x "$MNT/sbin/init" || -L "$MNT/sbin/init" ]]; then root_part=$part; break; fi
    umount "$MNT"
done
[[ -n "$root_part" ]] || die "no ext4 root filesystem with /sbin/init found"
log "root filesystem: $root_part"

# bin_version <path> <args...> — run the binary from the image under the host
# kernel. Same architecture only; on a cross-built image this is skipped and
# the version is left empty rather than reported wrong.
native=true
[[ "$(uname -m)" == x86_64  && "$ARCH" != amd64 ]] && native=false
[[ "$(uname -m)" == aarch64 && "$ARCH" != arm64 ]] && native=false

bin_version() {
    local path=$1; shift
    [[ -x "$MNT$path" ]] || return 1
    [[ "$native" == true ]] || return 0
    "$MNT$path" "$@" 2>/dev/null | head -1 || true
}

for required in /usr/bin/kubeadm /usr/bin/kubelet /usr/bin/kubectl \
                /usr/bin/containerd /usr/bin/runc /usr/bin/crictl; do
    [[ -x "$MNT$required" ]] || die "missing required binary: $required"
done
[[ -d "$MNT/opt/cni/bin" ]] && [[ -n "$(ls -A "$MNT/opt/cni/bin")" ]] ||
    die "missing CNI plugins in /opt/cni/bin"
[[ -f "$MNT/etc/containerd/config.toml" ]] || die "missing /etc/containerd/config.toml"
[[ -d "$MNT/etc/kubernetes/manifests" ]] || die "missing /etc/kubernetes/manifests"
log "all required binaries present"

# SystemdCgroup is not cosmetic: with the cgroup v2 driver mismatched, kubelet
# and containerd disagree about who owns the cgroup and pods fail to start.
grep -q 'SystemdCgroup = true' "$MNT/etc/containerd/config.toml" ||
    die "containerd config does not set SystemdCgroup = true"

kubelet_v=$(bin_version /usr/bin/kubelet --version | awk '{print $2}' || true)
if [[ "$native" == true ]]; then
    [[ "$kubelet_v" == "v${K8S}" ]] ||
        die "kubelet reports '${kubelet_v}', expected v${K8S}"
    log "kubelet version verified: ${kubelet_v}"
else
    log "cross-architecture image: binary versions not executed, presence only"
fi

containerd_v=$(bin_version /usr/bin/containerd --version | awk '{print $3}' || true)
runc_v=$(bin_version /usr/bin/runc --version | awk 'NR==1{print $3}' || true)
crictl_v=$(bin_version /usr/bin/crictl --version | awk '{print $3}' || true)

# Preloaded control-plane images are what makes the first boot fast; record
# whether kubeadm's pull actually landed instead of assuming it did.
images_preloaded=false
if [[ -d "$MNT/var/lib/containerd" ]] &&
   [[ -n "$(ls -A "$MNT/var/lib/containerd" 2>/dev/null)" ]]; then
    images_preloaded=true
fi

jq -n \
    --arg os_name "$OS_NAME" --arg os_version "$OS_VERSION" \
    --arg k8s_version "$K8S" --arg arch "$ARCH" \
    --arg kubelet_version "${kubelet_v#v}" \
    --arg containerd_version "${containerd_v#v}" \
    --arg runc_version "${runc_v#v}" \
    --arg crictl_version "${crictl_v#v}" \
    --arg build_run_id "${GITHUB_RUN_ID:-}" \
    --arg source_commit "${GITHUB_SHA:-}" \
    --argjson images_preloaded "$images_preloaded" \
    --argjson boot_verified false \
    '{os_name:$os_name, os_version:$os_version, k8s_version:$k8s_version,
      arch:$arch, kubelet_version:$kubelet_version,
      containerd_version:$containerd_version, runc_version:$runc_version,
      crictl_version:$crictl_version, build_run_id:$build_run_id,
      source_commit:$source_commit, images_preloaded:$images_preloaded,
      boot_verified:$boot_verified}
     | with_entries(select(.value != ""))' >"$OUT"

log "wrote $OUT"
cat "$OUT"
