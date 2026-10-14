#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Retire the images a new upload supersedes, once the gate has accepted it.
#
#   hack/glance/retire.sh <new-image-id> <old-image-ids-file>
#
# push.sh records the images already under the name before it uploads; this
# runs only after hack/gate.sh succeeded (passed, or skipped where there is no
# compute to boot on), so a rejected image or an unusable cloud leaves the
# working image in place.

set -Eeuo pipefail

log()  { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die()  { printf '%s\n' "$*" >&2; exit 1; }

[[ $# -eq 2 ]] || die "usage: $0 <new-image-id> <old-image-ids-file>"
NEW_ID=$1
OLD_IDS_FILE=$2
[[ -f "$OLD_IDS_FILE" ]] || die "no such file: $OLD_IDS_FILE"

name=$(openstack image show "$NEW_ID" -f value -c name)

while read -r old_id; do
    [[ -n "$old_id" && "$old_id" != "$NEW_ID" ]] || continue
    if openstack image delete "$old_id" >/dev/null 2>&1; then
        log "retired previous image ${old_id}"
        continue
    fi
    # A CoW parent with live clones cannot be deleted, and that is expected
    # - but leaving it under the same name is not. Two images called
    # ubuntu-24.04-v1.37.0-amd64 make every later `image show <name>`
    # ambiguous, including the one a cluster template resolves. Rename the
    # old one so the name keeps pointing at exactly one image.
    superseded="${name}-superseded-$(date +%Y%m%d-%H%M)"
    if openstack image set --name "$superseded" "$old_id" >/dev/null 2>&1; then
        warn "previous image ${old_id} still has clones; renamed to ${superseded}"
    else
        warn "previous image ${old_id} kept AND still named ${name}: the name is now ambiguous"
    fi
done <"$OLD_IDS_FILE"
