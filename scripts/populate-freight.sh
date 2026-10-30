#!/usr/bin/env bash
# Creates Kargo Freight for argoproj/rollouts-demo color tags, oldest first.
#
# The demo images never change, so a Warehouse would only ever produce one
# Freight. This fills the timeline so there is something to promote.
#
# Usage: scripts/populate-freight.sh <project> <warehouse> [tag...]
set -euo pipefail

PROJECT=${1:?project (Kargo project namespace) required}
WAREHOUSE=${2:?warehouse name required}
shift 2
TAGS=("$@")
[ ${#TAGS[@]} -gt 0 ] || TAGS=(blue green yellow orange purple)
REPO=argoproj/rollouts-demo

token=$(curl -sf "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$REPO:pull" |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')

for tag in "${TAGS[@]}"; do
  digest=$(curl -sfI -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    "https://registry-1.docker.io/v2/$REPO/manifests/$tag" |
    tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}')
  # Kargo's webhook names Freight after a hash of its contents, so re-running
  # yields the same names and existing Freight is left alone.
  if ! out=$(kubectl create -o jsonpath='{.metadata.name}' -f - 2>&1 <<EOF
apiVersion: kargo.akuity.io/v1alpha1
kind: Freight
metadata:
  namespace: $PROJECT
origin:
  kind: Warehouse
  name: $WAREHOUSE
images:
  - repoURL: $REPO
    tag: $tag
    digest: $digest
EOF
  ); then
    case $out in
      *AlreadyExists*) out="already exists" ;;
      *) echo "$tag: $out" >&2; exit 1 ;;
    esac
  fi
  echo "$tag  $out"
  # Kargo orders Freight by creationTimestamp, which has 1s resolution.
  sleep 1.1
done
