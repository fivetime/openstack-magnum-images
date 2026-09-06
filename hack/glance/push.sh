#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Upload one built node image to Glance with the property contract the
# Cluster API driver for Magnum needs.
#
#   hack/glance/push.sh <image-file> <manifest-file>
#
# The store-routing logic (upload private, copy-image into an explicit store,
# poll until the store really carries it, drop the others) is taken from
# fivetime/openstack-cloud-images lib/glance.sh so both image factories reach
# Glance the same way.
#
# Environment:
#   OS_CLOUD / OS_*        OpenStack auth
#   IMAGE_STORE            Glance store to place the image in. Production MUST
#                          set this to the RBD store: Cinder can only CoW-clone
#                          a raw image that already lives in the same Ceph
#                          cluster, and Nova only boots without a full copy for
#                          the same reason. Without it the image lands in
#                          whatever the default is and every node boot pays a
#                          full download.
#   VISIBILITY             public|private|shared|community (default private;
#                          the gate promotes to public only after a real
#                          cluster came up on the image)
#   IMAGE_IMPORT_TIMEOUT   seconds to wait for the store copy (default 900)
#   NAME                   override the generated image name

set -Eeuo pipefail

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf '%s\n' "$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <image-file> <manifest-file>"
IMAGE_FILE=$1
MANIFEST=$2
[[ -f "$IMAGE_FILE" ]] || die "no such image file: $IMAGE_FILE"
[[ -f "$MANIFEST" ]]   || die "no such manifest: $MANIFEST"

command -v openstack >/dev/null || die "the openstack client is required"
command -v jq >/dev/null        || die "jq is required"
[[ -n "${OS_CLOUD:-}${OS_AUTH_URL:-}" ]] || die "set OS_CLOUD or OS_AUTH_URL"

VISIBILITY=${VISIBILITY:-private}
IMAGE_STORE=${IMAGE_STORE:-}
IMAGE_IMPORT_TIMEOUT=${IMAGE_IMPORT_TIMEOUT:-900}
[[ -z "$IMAGE_STORE" || "$IMAGE_STORE" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "IMAGE_STORE contains unsupported characters"

# m <key> — a manifest value, or the empty string when the key is absent.
#
# NOT `.[$k] // ""`: jq's alternative operator treats false the same as null,
# so a boolean false comes back as "" and the caller drops the property. That
# silently loses exactly the fields worth recording - boot_verified=false on
# an image no gate has booted would simply not be published at all.
m() { jq -r --arg k "$1" 'if has($k) then .[$k] else "" end' "$MANIFEST"; }

OS_NAME=$(m os_name);  OS_VERSION=$(m os_version)
K8S=$(m k8s_version);  ARCH=$(m arch)
[[ -n "$OS_NAME" && -n "$K8S" && -n "$ARCH" ]] ||
    die "manifest is missing os_name/k8s_version/arch: $MANIFEST"

NAME=${NAME:-${OS_NAME}-${OS_VERSION}-v${K8S}-${ARCH}}

# Glance spells architectures the libvirt way, not the Go way.
case "$ARCH" in
    amd64) GLANCE_ARCH=x86_64 ;;
    arm64) GLANCE_ARCH=aarch64 ;;
    *)     die "unknown architecture: $ARCH" ;;
esac

# os_distro is not decoration: magnum/api/attr_validator.py raises
# OSDistroFieldNotFound when it is absent, so a cluster template cannot even
# be created against an image that lacks it.
case "$OS_NAME" in
    ubuntu)      OS_DISTRO=ubuntu ;;
    debian)      OS_DISTRO=debian ;;
    rockylinux)  OS_DISTRO=rocky ;;
    *)           OS_DISTRO=$OS_NAME ;;
esac

props=(
    --property "os_distro=${OS_DISTRO}"
    --property "os_version=${OS_VERSION}"
    --property "architecture=${GLANCE_ARCH}"
    --property "hw_firmware_type=uefi"          # block-device-kubernetes lays down an ESP
    --property "k8s_version=${K8S}"
)
# Provenance and capability flags, straight from the manifest. Absent keys are
# simply not published rather than guessed.
for key in containerd_version runc_version cni_plugins_version crictl_version \
           crun_version runsc_version kata_version \
           build_run_id source_commit boot_verified images_preloaded; do
    value=$(m "$key")
    [[ -n "$value" ]] && props+=(--property "${key}=${value}")
done

log "uploading ${NAME}"
log "  file=${IMAGE_FILE} ($(du -h "$IMAGE_FILE" | cut -f1))"
log "  store=${IMAGE_STORE:-<default>} visibility=${VISIBILITY}"

# Replace any image of the same name; names are (os, k8s, arch) coordinates,
# not versions, so a rebuild of the same coordinate supersedes the old one.
old_id=$(openstack image show "$NAME" -f value -c id 2>/dev/null || true)

if [[ -z "$IMAGE_STORE" ]]; then
    warn "IMAGE_STORE is unset: the image will not be CoW-cloneable on RBD"
    image_id=$(openstack image create "$NAME" \
        --disk-format raw --container-format bare \
        "--${VISIBILITY}" "${props[@]}" --file "$IMAGE_FILE" -f value -c id)
else
    # Create private first: an image must not be visible to tenants until it
    # actually sits in the store that makes it cheap to boot.
    image_id=$(openstack image create "$NAME" \
        --disk-format raw --container-format bare \
        --private "${props[@]}" --file "$IMAGE_FILE" -f value -c id)

    openstack image import --method copy-image --store "$IMAGE_STORE" --wait "$image_id"

    # --wait returns early when the source copy is already active, so poll the
    # store list until the requested store really appears.
    deadline=$((SECONDS + IMAGE_IMPORT_TIMEOUT)); stores=
    while ((SECONDS < deadline)); do
        stores=$(openstack image show "$image_id" -f json | jq -r '.properties.stores // ""')
        [[ ",${stores}," == *",${IMAGE_STORE},"* ]] && break
        sleep 5
    done
    [[ ",${stores}," == *",${IMAGE_STORE},"* ]] || {
        warn "image ${NAME} never reached store ${IMAGE_STORE}"
        openstack image delete "$image_id" >/dev/null 2>&1 || true
        exit 1
    }
    for store in ${stores//,/ }; do
        [[ "$store" != "$IMAGE_STORE" ]] && openstack image delete --store "$store" "$image_id"
    done
    openstack image set "--${VISIBILITY}" "$image_id"
fi

# Only now is the new image safe to keep; retire the one it replaces. Doing it
# last means a failed upload leaves the working image in place.
if [[ -n "$old_id" && "$old_id" != "$image_id" ]]; then
    if openstack image delete "$old_id" >/dev/null 2>&1; then
        log "  retired previous image ${old_id}"
    else
        # A CoW parent with live clones cannot be deleted, and that is expected
        # - but leaving it under the same name is not. Two images called
        # ubuntu-24.04-v1.37.0-amd64 make every later `image show <name>`
        # ambiguous, including the one a cluster template resolves. Rename the
        # old one so the name keeps pointing at exactly one image.
        superseded="${NAME}-superseded-$(date +%Y%m%d-%H%M)"
        if openstack image set --name "$superseded" "$old_id" >/dev/null 2>&1; then
            warn "  previous image ${old_id} still has clones; renamed to ${superseded}"
        else
            warn "  previous image ${old_id} kept AND still named ${NAME}: the name is now ambiguous"
        fi
    fi
fi

openstack image show "$image_id" -c id -c name -c status -c disk_format -c visibility
printf '%s\n' "$image_id" >"${IMAGE_ID_FILE:-image-id.txt}"
log "image_id=${image_id}"
