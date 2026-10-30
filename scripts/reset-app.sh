#!/usr/bin/env bash
# Removes everything an agent created for the demo app, so it can be redone:
# Argo CD Applications labelled app-deployment=true (and their namespaces),
# all Kargo projects, and the app-deployment branch (worktree, local, remote).
set -uo pipefail

cd "$(dirname "$0")/.."
REPO=https://github.com/alexmt/ai-bootstrap-demo.git
BRANCH=app-deployment

apps=$(kubectl -n argocd get applications -l app-deployment=true -o name)
namespaces=$(kubectl -n argocd get applications -l app-deployment=true \
  -o jsonpath='{range .items[*]}{.spec.destination.namespace}{"\n"}{end}' | sort -u)
if [ -n "$apps" ]; then
  echo "Deleting Argo CD applications"
  # shellcheck disable=SC2086
  kubectl -n argocd delete $apps --wait
fi
if [ -n "$namespaces" ]; then
  echo "Deleting app namespaces"
  # shellcheck disable=SC2086
  kubectl delete namespace $namespaces --wait --ignore-not-found
fi

echo "Deleting Kargo projects"
kubectl delete projects.kargo.akuity.io --all --wait
kubectl wait --for=delete namespace -l kargo.akuity.io/project=true --timeout=180s 2>/dev/null

echo "Deleting branch $BRANCH"
git worktree remove --force ".worktrees/$BRANCH" 2>/dev/null
git branch -D "$BRANCH" 2>/dev/null
git -c credential.helper= -c credential.helper='!gh auth git-credential' \
  push "$REPO" --delete "$BRANCH" 2>/dev/null || echo "  (no remote branch)"
