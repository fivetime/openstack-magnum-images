#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
#
# Resolve the newest usable version of every component at build time.
#
#   hack/versions.sh <kubernetes-version>     # e.g. 1.37.0
#
# Emits KEY=VALUE lines that map straight onto the DIB_*_VERSION variables the
# elements already honour, so nothing under elements/ has to change:
#
#   CONTAINERD_VERSION=2.3.5
#   RUNC_VERSION=1.4.3
#   CNI_PLUGINS_VERSION=1.9.1
#   CRI_TOOLS_VERSION=1.37.0
#
# ---------------------------------------------------------------------------
# Why not /releases/latest
# ---------------------------------------------------------------------------
# GitHub returns the most recent non-prerelease sorted by the tag's created_at,
# NOT by semver. Every project here maintains several release branches at once
# and cuts patches for all of them on the same day:
#
#   containerd 2026-09-04:  v2.3.5  v2.2.8  v2.0.12  v1.7.35   <- all same day
#   cri-o      2026-09-02:  v1.36.5 v1.35.8 v1.34.13           <- all same day
#
# Whichever tag happens to land last wins, so /releases/latest can hand back
# containerd 1.7.35 in place of 2.3.5 - a two-major regression, with no error.
#
# The rule used here instead: list the releases, drop drafts and prereleases,
# optionally keep only one series, then sort by semver and take the maximum.
#
# ---------------------------------------------------------------------------
# Why cri-tools is pinned to the Kubernetes minor
# ---------------------------------------------------------------------------
# cri-tools versions track Kubernetes minors (crictl 1.37.x goes with 1.37.x).
# Taking the global newest would put a crictl from a different minor on the
# node, which is exactly the mismatch upstream's flat "1.36.0" default already
# suffers from.
#
# Environment:
#   CONTAINERD_SERIES   restrict containerd to a series, e.g. "2.3" (default: newest)
#   GH_TOKEN            raises the GitHub API rate limit; optional

set -Eeuo pipefail

log() { printf '[versions] %s\n' "$*" >&2; }
die() { printf '[versions] %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage: $0 <kubernetes-version>"
K8S=$1
[[ "$K8S" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]] || die "not a Kubernetes version: $K8S"
K8S_MINOR=${BASH_REMATCH[1]}

command -v jq >/dev/null || die "jq is required"

api() {
    local url=$1
    if [[ -n "${GH_TOKEN:-}" ]]; then
        curl -fsS --retry 3 -H "Authorization: Bearer ${GH_TOKEN}" "$url"
    else
        curl -fsS --retry 3 "$url"
    fi
}

# newest <owner/repo> [series-prefix]
#
# The maximum published, non-draft, non-prerelease semver tag, optionally
# restricted to one series. Returns the bare version with no leading v.
newest() {
    local repo=$1 series=${2:-} versions
    versions=$(api "https://api.github.com/repos/${repo}/releases?per_page=100" |
        jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name') ||
        die "cannot list releases for ${repo}"

    # Keep plain vX.Y.Z tags. Anything carrying a suffix (-rc, -beta, +incompat)
    # is not a release we want to bake into an image.
    versions=$(printf '%s\n' "$versions" | sed -n 's/^v\?\([0-9]\+\.[0-9]\+\.[0-9]\+\)$/\1/p')
    [[ -n "$series" ]] && versions=$(printf '%s\n' "$versions" | grep "^${series}\.") || true

    local best
    best=$(printf '%s\n' "$versions" | sort -V | tail -1)
    [[ -n "$best" ]] || die "no usable release found for ${repo}${series:+ series ${series}}"
    printf '%s\n' "$best"
}

CONTAINERD=$(newest containerd/containerd "${CONTAINERD_SERIES:-}")
RUNC=$(newest opencontainers/runc)
CNI=$(newest containernetworking/plugins)

# cri-tools ships one series per Kubernetes minor. When a brand new Kubernetes
# minor lands before its cri-tools counterpart, fall back to the newest
# available rather than failing the build, and say which happened.
if CRICTL=$(newest kubernetes-sigs/cri-tools "$K8S_MINOR" 2>/dev/null); then
    log "cri-tools ${CRICTL} matches Kubernetes ${K8S_MINOR}"
else
    CRICTL=$(newest kubernetes-sigs/cri-tools)
    log "NOTE: no cri-tools ${K8S_MINOR}.x published yet; falling back to ${CRICTL}"
fi

log "kubernetes=${K8S} containerd=${CONTAINERD} runc=${RUNC} cni=${CNI} crictl=${CRICTL}"

emit() {
    if [[ -n "${GITHUB_ENV:-}" ]]; then printf '%s\n' "$1" >>"$GITHUB_ENV"; fi
    printf '%s\n' "$1"
}
emit "CONTAINERD_VERSION=${CONTAINERD}"
emit "RUNC_VERSION=${RUNC}"
emit "CNI_PLUGINS_VERSION=${CNI}"
emit "CRI_TOOLS_VERSION=${CRICTL}"
