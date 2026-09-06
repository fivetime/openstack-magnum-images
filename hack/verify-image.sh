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

# The drop-ins are only read if the main config imports them, and only
# interpreted if it declares the same config version. magnum-cluster-api
# replaces this file at first boot with exactly this shape, so an image that
# does not match it is tested in a shape it never runs in - which is how crun
# and gvisor came out configured on the image and absent on a real node.
grep -q 'imports = \["/etc/containerd/conf.d/\*.toml"\]' "$MNT/etc/containerd/config.toml" ||
    die "containerd config does not import /etc/containerd/conf.d"
grep -q '^version = 2$' "$MNT/etc/containerd/config.toml" ||
    die "containerd config is not version 2; drop-ins written for it would be ignored"

# The containerd element disables the unused snapshotters because, in its own
# words, they "prevent containerd from running without proper configuration".
# Losing that line let the btrfs snapshotter fail to find its mount info, which
# cascaded into the CRI plugin never loading - and `containerd config dump`
# passed, because the config was valid and only the runtime behaviour was not.
grep -q '^disabled_plugins' "$MNT/etc/containerd/config.toml" ||
    die "containerd config lost disabled_plugins; the CRI plugin will not load"

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

# The sandbox image is recorded, not asserted here. Whether it was actually
# preloaded is checked inside the chroot by the containerd-conf-d element's
# post-install.d/81-verify-sandbox-preloaded, which can ask containerd through
# ctr and get an exact answer.
#
# This script cannot. Reading it back out of the bolt metadata db means
# grepping a binary file whose keys are length-prefixed rather than
# NUL-terminated, and the match runs into the next record - the first version
# of this check read "registry.k8s.io/pause:3.10.2M" and failed a build whose
# image was correct. Tag characters include letters, so no character class
# fixes it.
sandbox_image=$(awk -F'"' '/^[[:space:]]*sandbox_image[[:space:]]*=/{print $2; exit}' \
                "$MNT/etc/containerd/config.toml")
[[ -n "$sandbox_image" ]] || die "containerd config names no sandbox_image"
log "sandbox image: ${sandbox_image}"

# Optional runtimes. Recorded only when actually present, and - for crun -
# only when containerd is really configured to execute it: having the binary
# on the image proves nothing about which runtime a pod gets.
crun_v=""
if [[ -x "$MNT/usr/bin/crun" ]] &&
   grep -rq 'BinaryName = "/usr/bin/crun"' "$MNT/etc/containerd/conf.d/"; then
    # `crun --version` prints "crun version 1.29.1": the number is field 3.
    # Taking field 2 yielded the word "version", which ${crun_v#v} then turned
    # into "ersion" - published to Glance as the crun version before anyone
    # noticed. Reading a value back is only worth anything if the parse is right.
    crun_v=$(bin_version /usr/bin/crun --version | awk '{print $3}' || true)
    log "containerd default runtime is crun ${crun_v}"
fi
runsc_v=""
if [[ -x "$MNT/usr/bin/runsc" ]] &&
   grep -rq "runtimes.gvisor" "$MNT/etc/containerd/conf.d/"; then
    runsc_v=$(bin_version /usr/bin/runsc --version | awk '{print $3}' || true)
    log "gvisor runtime handler present"
fi
# kata 4.x ships only the Rust runtime in kata-static, so there is no
# /opt/kata/bin/kata-runtime to ask any more - looking for it recorded no kata
# version at all for an image that had five working kata handlers. The shim is
# the thing that must exist for those handlers to work, so it is what is
# checked.
#
# The version comes from the tarball name the element recorded at install time
# rather than from the build variable, for the same reason as everything else
# here: a build that installed something other than what it was asked for must
# not be able to describe itself as correct. The shim's own --version is tried
# first and the filename is the fallback.
kata_v=""
kata_handlers=""
if [[ -x "$MNT/opt/kata/runtime-rs/bin/containerd-shim-kata-v2" ]] &&
   grep -rq "runtimes.kata-" "$MNT/etc/containerd/conf.d/"; then
    kata_v=$(bin_version /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 --version |
             grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ -z "$kata_v" && -f "$MNT/etc/kata-static.sha256" ]]; then
        kata_v=$(grep -oE 'kata-static-[0-9]+\.[0-9]+\.[0-9]+' "$MNT/etc/kata-static.sha256" |
                 head -1 | sed 's/^kata-static-//' || true)
    fi

    # The handler names, not just "kata is here". magnum-cluster-api creates a
    # RuntimeClass per handler and the two lists have to agree; recording what
    # the image actually registered is what makes a disagreement visible.
    kata_handlers=$(grep -rhoE 'runtimes\.(kata-[a-z0-9-]+)\]' \
                    "$MNT/etc/containerd/conf.d/" |
                    sed -E 's/^runtimes\.//; s/\]$//' | sort -u | paste -sd, - || true)
    log "kata handlers present: ${kata_handlers:-none} (kata ${kata_v:-unknown})"

    # kata backs guest memory with a file on /dev/shm, and systemd's default
    # for it is half of RAM - smaller than the 2048 MB guest kata asks for on
    # any node with 4 GB. The guest then faults in firmware with "kvm run
    # failed Bad address", which the shim reports as a vsock timeout. Checked
    # here because the element writing the fstab line and the image shipping it
    # are two different things.
    grep -qE '^[^#]*[[:space:]]/dev/shm[[:space:]]' "$MNT/etc/fstab" ||
        die "kata is installed but /etc/fstab does not size /dev/shm; every QEMU sandbox would fail"
    log "/dev/shm sized for kata: $(grep -E '^[^#]*[[:space:]]/dev/shm[[:space:]]' "$MNT/etc/fstab")"
fi

jq -n \
    --arg os_name "$OS_NAME" --arg os_version "$OS_VERSION" \
    --arg k8s_version "$K8S" --arg arch "$ARCH" \
    --arg kubelet_version "${kubelet_v#v}" \
    --arg containerd_version "${containerd_v#v}" \
    --arg runc_version "${runc_v#v}" \
    --arg crictl_version "${crictl_v#v}" \
    --arg crun_version "${crun_v#v}" \
    --arg runsc_version "$runsc_v" \
    --arg kata_version "${kata_v#v}" \
    --arg kata_handlers "$kata_handlers" \
    --arg build_run_id "${GITHUB_RUN_ID:-}" \
    --arg source_commit "${GITHUB_SHA:-}" \
    --argjson images_preloaded "$images_preloaded" \
    --argjson boot_verified false \
    '{os_name:$os_name, os_version:$os_version, k8s_version:$k8s_version,
      arch:$arch, kubelet_version:$kubelet_version,
      containerd_version:$containerd_version, runc_version:$runc_version,
      crictl_version:$crictl_version, crun_version:$crun_version,
      runsc_version:$runsc_version, kata_version:$kata_version,
      kata_handlers:$kata_handlers,
      build_run_id:$build_run_id,
      source_commit:$source_commit, images_preloaded:$images_preloaded,
      boot_verified:$boot_verified}
     | with_entries(select(.value != ""))' >"$OUT"

log "wrote $OUT"
cat "$OUT"
