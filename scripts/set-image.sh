#!/usr/bin/env bash
#
# Pin Clutch images to exact tags in one environment's compose files.
#
#   bash scripts/set-image.sh <stage|mainnet> <image>                print the tag pinned for <image>
#   bash scripts/set-image.sh <stage|mainnet> <image>=<tag> ...      pin, in the working tree
#   PUSH=1 bash scripts/set-image.sh <stage|mainnet> <image>=<tag>   pin, commit, push to main (CI only)
#
# Why pins and not `latest`. Every deploy used to pull the newest `latest` of every image, so a
# deploy for one repo's change also shipped whatever any other repo had built since the last one.
# On 2026-09-25 a demo-app deploy would have rolled out treasury images (the GasFree rail, treasury
# PR #53) that nobody had decided to ship. Now a deploy ships exactly what these files say, and a
# tag moves only when this script, or a reviewed commit, moves it.
#
# The tags are the `sha-<7>` tags every Clutch image workflow already pushes (docker/metadata-action,
# type=sha). A rebuild of the same commit can point a sha tag at a new digest; the code is the same.
#
# Each environment's pins live in exactly two files and nowhere else. The stage overlays must not
# set a Clutch image, because an overlay's `image:` silently wins over the pinned base.
# scripts/test-set-image.sh checks that on every PR that touches a compose file.

set -euo pipefail

IMAGES="clutch-node clutch-hub-api clutch-hub-demo-app clutch-explorer-backend clutch-explorer-frontend
        clutch-treasury clutch-orchestrator clutch-tron-signer"
ROOT="${PIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

die()   { echo "set-image: $*" >&2; exit 1; }
usage() { die "usage: set-image.sh <stage|mainnet> <image> | <image>=<tag> [<image>=<tag> ...]"; }

files_for() {
  case "$1" in
    stage)   echo "docker-compose.yml docker-compose.treasury.yml" ;;
    mainnet) echo "docker-compose.mainnet.yml docker-compose.mainnet.treasury.yml" ;;
  esac
}

known_image() {
  local i
  for i in $IMAGES; do [ "$i" = "$1" ] && return 0; done
  return 1
}

# The distinct tags <image> has in <env>'s files, one per line. Empty when it is not pinned there.
tags_in() {
  local f
  for f in $(files_for "$1"); do
    [ -f "$ROOT/$f" ] || continue
    grep -oE "image:[[:space:]]*ghcr\.io/clutchprotocol/$2:[A-Za-z0-9._-]+" "$ROOT/$f" || true
  done | sed 's/.*://' | sort -u
}

# Does ghcr.io have <image>:<tag>? Asked anonymously, because every Clutch image is public.
registry_has() {
  local token code
  token=$(curl -fsS --max-time 20 "https://ghcr.io/token?scope=repository:clutchprotocol/$1:pull" \
            | sed -n 's/.*"token":"\([^"]*\)".*/\1/p') || return 1
  [ -n "$token" ] || return 1
  code=$(curl -s --max-time 20 -o /dev/null -w '%{http_code}' -I \
           -H "Authorization: Bearer $token" \
           -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
           "https://ghcr.io/v2/clutchprotocol/$1/manifests/$2") || return 1
  [ "$code" = "200" ]
}

ENV_NAME="${1:-}"
case "$ENV_NAME" in stage|mainnet) ;; *) usage ;; esac
shift
[ $# -ge 1 ] || usage

# Print: one argument, no '='.
if [ $# -eq 1 ] && [[ "$1" != *=* ]]; then
  known_image "$1" || die "unknown image '$1'"
  tags=$(tags_in "$ENV_NAME" "$1")
  [ -n "$tags" ] || die "$1 is not pinned in $ENV_NAME"
  [ "$(printf '%s\n' "$tags" | wc -l)" -eq 1 ] \
    || die "$1 has different tags in $ENV_NAME: $(printf '%s\n' "$tags" | tr '\n' ' ')"
  echo "$tags"
  exit 0
fi

# Check every pair before touching a file. A set that moves one image and then refuses the next
# leaves the files describing a deployment nobody asked for.
PAIRS=()
for p in "$@"; do
  [[ "$p" == *=* ]] || die "expected <image>=<tag>, got '$p'"
  img="${p%%=*}"
  tag="${p#*=}"
  known_image "$img" || die "unknown image '$img'"
  [[ "$tag" =~ ^sha-[0-9a-f]{7}$ ]] || die "the tag for $img must be sha-<7 lower-case hex>, got '$tag'"
  [ -n "$(tags_in "$ENV_NAME" "$img")" ] || die "$img is not pinned in $ENV_NAME, so there is nothing to move"
  if [ "${SKIP_REGISTRY_CHECK:-}" != "1" ]; then
    registry_has "$img" "$tag" \
      || die "ghcr.io/clutchprotocol/$img:$tag does not exist, or ghcr.io did not answer"
  fi
  PAIRS+=("$img=$tag")
done

apply() {
  local p img tag f
  for p in "${PAIRS[@]}"; do
    img="${p%%=*}"
    tag="${p#*=}"
    for f in $(files_for "$ENV_NAME"); do
      [ -f "$ROOT/$f" ] || continue
      sed -i -E "s#(image:[[:space:]]*ghcr\.io/clutchprotocol/$img):[A-Za-z0-9._-]+#\1:$tag#g" "$ROOT/$f"
    done
  done
}

if [ "${PUSH:-}" != "1" ]; then
  apply
  echo "$ENV_NAME: ${PAIRS[*]}"
  exit 0
fi

# PUSH=1: commit the pin and push it to main. Every attempt starts again from origin/main, which
# throws away anything uncommitted: right on a CI runner, never what you want in your own checkout.
[ "${CI:-}" = "true" ] || die "PUSH=1 resets the checkout to origin/main on every attempt; it is for CI only"
MSG="deploy($ENV_NAME): pin ${PAIRS[*]}"
for attempt in 1 2 3 4 5; do
  # FETCH_HEAD, not origin/main: a CI checkout's refspec need not update the tracking ref.
  git -C "$ROOT" fetch -q origin main
  git -C "$ROOT" reset -q --hard FETCH_HEAD
  apply
  if git -C "$ROOT" diff --quiet; then
    echo "$ENV_NAME: already pinned to ${PAIRS[*]}; nothing to commit"
    exit 0
  fi
  git -C "$ROOT" commit -q -am "$MSG"
  if git -C "$ROOT" push -q origin HEAD:main; then
    git -C "$ROOT" log --oneline -1
    exit 0
  fi
  # Someone pushed to main between the fetch and the push. Start again on top of their commit.
  echo "main moved while pinning (attempt $attempt of 5); retrying"
  sleep $((attempt * 2))
done
die "could not push the pin after 5 attempts"
