#!/usr/bin/env bash
set -Eeuo pipefail
: "${STAGING_REF:?}" "${SOURCE_REVISION:?}" "${RUNNER_TEMP:?}"
: "${GITHUB_STEP_SUMMARY:?}" "${GITHUB_RUN_ID:?}" "${GITHUB_RUN_ATTEMPT:?}"

: "${GITOPS_TOKEN:?}"
auth="$(printf 'x-access-token:%s' "$GITOPS_TOKEN" | base64 -w 0)"
echo "::add-mask::$auth"
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=http.https://github.com/.extraheader
export GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $auth"
unset GITOPS_TOKEN auth
root="$(git rev-parse --show-toplevel)"
mkdir -p "$root/reports/gitops"

git fetch origin main
current_main="$(git rev-parse FETCH_HEAD)"
if [[ "$current_main" != "$SOURCE_REVISION" ]]; then
  printf 'Superseded source %s; main is now %s. No GitOps update.\n' \
    "$SOURCE_REVISION" "$current_main" | tee "$root/reports/gitops/status.txt"
  cat "$root/reports/gitops/status.txt" >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi
branch="gitops-staging"
worktree="$RUNNER_TEMP/gitops-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
remote="$(git ls-remote --heads origin "refs/heads/$branch")"
if [[ -n "$remote" ]]; then
  git fetch origin "refs/heads/$branch:refs/remotes/origin/$branch"
  git worktree add -b "$branch" "$worktree" "refs/remotes/origin/$branch"
else
  git worktree add --detach "$worktree" "$SOURCE_REVISION"
  git -C "$worktree" switch --orphan "$branch"
fi
trap 'git worktree remove --force "$worktree" >/dev/null 2>&1 || true' EXIT
git -C "$worktree" config user.name 'github-actions[bot]'
git -C "$worktree" config user.email '41898282+github-actions[bot]@users.noreply.github.com'
if [[ -z "$remote" ]]; then
  mkdir -p "$worktree/k8s-manifests"
  cp -R "$root/k8s-manifests/staging" "$worktree/k8s-manifests/staging"
  git -C "$worktree" add k8s-manifests/staging
  git -C "$worktree" commit -m 'Initialize staging manifest templates'
fi

mkdir -p "$worktree/k8s-manifests/staging"
cp "$root/k8s-manifests/staging/namespace.yaml" "$worktree/k8s-manifests/staging/"
cp "$root/k8s-manifests/staging/service.yaml" "$worktree/k8s-manifests/staging/"
cp "$root/k8s-manifests/staging/deployment.yaml" "$worktree/k8s-manifests/staging/"
python "$root/scripts/update_manifest.py" \
  --manifest "$worktree/k8s-manifests/staging/deployment.yaml" \
  --image "$STAGING_REF" --revision "$SOURCE_REVISION"
git -C "$worktree" add k8s-manifests/staging
git -C "$worktree" diff --cached --check
git -C "$worktree" diff --cached > "$root/reports/gitops/manifest.diff"
if git -C "$worktree" diff --cached --quiet; then
  echo 'Manifest already up to date' | tee "$root/reports/gitops/status.txt"
else
  git -C "$worktree" commit -m "Promote ${SOURCE_REVISION:0:12} to staging"
fi

git -C "$worktree" push origin "HEAD:refs/heads/$branch"
git -C "$worktree" log -1 --format='%H %s' > "$root/reports/gitops/commit.txt"
printf 'Desired state branch: %s\nImage: %s\n' "$branch" "$STAGING_REF" \
  | tee -a "$root/reports/gitops/status.txt"
cat "$root/reports/gitops/status.txt" >> "$GITHUB_STEP_SUMMARY"
