#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Emit the build matrix at run time. No version list is committed anywhere,
# so following upstream Kubernetes costs no pull request and no merge.
#
# Two independent sources, each authoritative for one question:
#
#   endoflife.date   which minor series are still maintained
#   dl.k8s.io        the exact newest patch of a given minor
#
# NOTE: do NOT use the GitHub API's /releases/latest for this. It returns the
# most recent non-prerelease sorted by the tag's created_at, not by semver.
# Kubernetes cuts patches for every supported branch on the same day, so as
# soon as an older minor's tag lands last, /releases/latest reports that older
# minor. It fails silently, which is the worst way to fail.
#
# Combinations already published are dropped, so a nightly run rebuilds only
# what actually changed.
#
# Outputs (GITHUB_OUTPUT, or stdout when run by hand):
#   matrix   {"include":[{os,os_name,os_version,element,release,k8s,arch,runner}, ...]}
#   empty    true when there is nothing to build

set -Eeuo pipefail

# os entries are the same four-field strings ci.yaml uses:
#   <name>/<version>/<dib-element>/<dib-release>
OS_LIST=${OS_LIST:-"debian/13/debian-minimal/trixie
ubuntu/22.04/ubuntu-minimal/jammy
ubuntu/24.04/ubuntu-minimal/noble
rockylinux/9/rocky-container/9"}

# Architectures to build. Both are native builds on their own runner; dib
# under qemu-user is slow and fragile, so cross-building is not an option.
ARCH_LIST=${ARCH_LIST:-"amd64 arm64"}

# Runner labels per architecture.
#
# amd64 builds on a self-hosted runner inside the datacenter by default, so the
# 3.3 GB image never crosses the internet on its way to Glance. Downloading one
# built image back from GitHub took 25 minutes at ~0.6 MB/s; over the full
# matrix that is more time than the builds themselves.
#
# arm64 has no self-hosted runner here - there is no arm64 hardware - so it
# stays on GitHub's arm runner and is published to Releases only.
RUNNER_AMD64=${RUNNER_AMD64:-ubuntu-24.04}
RUNNER_ARM64=${RUNNER_ARM64:-ubuntu-24.04-arm}

REPO=${GITHUB_REPOSITORY:-fivetime/openstack-magnum-images}
EOL_API=${EOL_API:-https://endoflife.date/api/v1/products/kubernetes}
DL_K8S=${DL_K8S:-https://dl.k8s.io/release}

log() { printf '%s\n' "$*" >&2; }

# published <asset> — true when a release asset of that name already exists.
#
# This answers one question only: has this exact combination already been
# built? It is not a judgement about whether the image is any good. So
# prereleases count too - an image that was built but never gated still does
# not need building again, and treating it as unbuilt would rebuild the whole
# matrix every night for as long as the optional Glance half stays off.
#
# What the release/prerelease distinction carries instead is whether the
# acceptance gate booted a cluster on the image. That claim lives on the
# release, and on the Glance image's boot_verified property and its
# visibility, which is where it can actually stop somebody using it.
#
# The published set is the state of record: it survives a lost cache, a re-run
# and a fork, and it is reachable from a GitHub-hosted runner (Glance is not).
# FORCE=true skips the check for a deliberate rebuild - which is also how you
# feed an already-built combination to the Glance half for the first time.
declare -A PUBLISHED=()
load_published() {
    [[ "${FORCE:-false}" == true ]] && { log "FORCE=true: rebuilding everything"; return; }
    local name n=0

    # The local image cache. With Releases optional this is often the only
    # record, and it is the one that matches what the Glance upload can
    # actually consume without fetching anything.
    if [[ -d "${IMAGE_CACHE:-/var/lib/magnum-images}" ]]; then
        while read -r name; do
            [[ -n "$name" ]] && { PUBLISHED["$(basename "$name")"]=1; ((n++)) || true; }
        done < <(find "${IMAGE_CACHE:-/var/lib/magnum-images}" -maxdepth 1 \
                      -name '*.manifest.json' 2>/dev/null)
        log "already built (local cache): ${n}"
    fi

    # Release assets, when there are any. Reachable from any runner, so it is
    # the record that survives a wiped cache or a different machine.
    if command -v gh >/dev/null; then
        while read -r name; do
            [[ -n "$name" ]] && PUBLISHED["$name"]=1
        done < <(gh release list --repo "$REPO" --limit 100 --json tagName --jq '.[].tagName' 2>/dev/null |
                 while read -r tag; do
                     gh release view "$tag" --repo "$REPO" --json assets \
                         --jq '.assets[].name' 2>/dev/null
                 done)
    fi
    log "already built (total distinct assets): ${#PUBLISHED[@]}"
}

maintained_minors() {
    curl -fsS --retry 3 "$EOL_API" |
        jq -r '.result.releases[] | select(.isMaintained == true) | .name' | sort -V
}

# latest_patch <minor> -> full version without the leading v, or empty.
latest_patch() {
    local minor=$1 v
    v=$(curl -fsS --retry 3 "${DL_K8S}/stable-${minor}.txt" 2>/dev/null) || return 1
    [[ "$v" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "${v#v}"
}

# resolve_versions echoes one full Kubernetes version per line.
#
# K8S_LIST pins the set explicitly, for a one-off build of a specific version.
# Left unset - the normal case - the set is discovered.
resolve_versions() {
    if [[ -n "${K8S_LIST:-}" ]]; then
        log "K8S_LIST is set; skipping discovery"
        printf '%s\n' $K8S_LIST
        return
    fi
    local minors=() minor k8s
    mapfile -t minors < <(maintained_minors)
    ((${#minors[@]})) || { log "no maintained Kubernetes minors reported"; exit 1; }
    log "maintained minors: ${minors[*]}"
    for minor in "${minors[@]}"; do
        if k8s=$(latest_patch "$minor"); then
            printf '%s\n' "$k8s"
        else
            # A maintained minor with no stable pointer is upstream's problem,
            # not ours; say so and carry on rather than failing the run.
            log "SKIP ${minor}: no ${DL_K8S}/stable-${minor}.txt"
        fi
    done
}

main() {
    command -v jq >/dev/null || { log "jq is required"; exit 1; }
    load_published

    local versions=()
    mapfile -t versions < <(resolve_versions)
    ((${#versions[@]})) || { log "no Kubernetes versions to build"; exit 1; }

    local include=() os arch k8s name version element release runner asset
    for k8s in "${versions[@]}"; do
        while read -r os; do
            [[ -n "$os" ]] || continue
            IFS=/ read -r name version element release <<<"$os"
            for arch in $ARCH_LIST; do
                case "$arch" in
                    amd64) runner=$RUNNER_AMD64 ;;
                    arm64) runner=$RUNNER_ARM64 ;;
                    *) log "SKIP unknown arch ${arch}"; continue ;;
                esac
                # The manifest, not the image: a release carries the record
                # of what was built, while the image itself stays in the
                # datacenter. Both the cache and a release have this name.
                asset="${name}-${version}-v${k8s}-${arch}.manifest.json"
                if [[ -n "${PUBLISHED[$asset]:-}" ]]; then
                    log "skip ${asset} (published)"
                    continue
                fi
                include+=("$(jq -nc \
                    --arg os "$os" --arg os_name "$name" --arg os_version "$version" \
                    --arg element "$element" --arg release "$release" \
                    --arg k8s "$k8s" --arg arch "$arch" --arg runner "$runner" \
                    '{os:$os, os_name:$os_name, os_version:$os_version,
                      element:$element, release:$release, k8s:$k8s,
                      arch:$arch, runner:$runner}')")
            done
        done <<<"$OS_LIST"
    done

    local matrix empty=false
    if ((${#include[@]})); then
        matrix=$(printf '%s\n' "${include[@]}" | jq -sc '{include: .}')
    else
        matrix='{"include":[]}'
        empty=true
    fi
    log "matrix entries: ${#include[@]}"

    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf 'matrix=%s\n' "$matrix" >>"$GITHUB_OUTPUT"
        printf 'empty=%s\n' "$empty" >>"$GITHUB_OUTPUT"
    else
        printf '%s\n' "$matrix" | jq .
    fi
}

main "$@"
