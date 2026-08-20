#!/bin/sh
set -eu

# Prepare a reviewable upstream merge branch without changing termux.
# Exit codes: 0 = branch prepared, 10 = already up to date, 1 = conflict.

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/can1357/oh-my-pi.git}"
UPSTREAM_REF="main"
SYNC_BRANCH=""

usage() {
	cat <<'EOF'
Usage: scripts/sync-upstream-pr.sh --branch <branch> [options]

Options:
  --branch <branch>       Local branch to prepare for the sync PR.
  --upstream-ref <ref>    Upstream branch or tag (default: main).
  --upstream-url <url>    Upstream repository URL.
  --remote <name>         Git remote name (default: upstream).
  -h, --help              Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--branch)
			SYNC_BRANCH="${2:?missing value for --branch}"
			shift 2
			;;
		--upstream-ref)
			UPSTREAM_REF="${2:?missing value for --upstream-ref}"
			shift 2
			;;
		--upstream-url)
			UPSTREAM_URL="${2:?missing value for --upstream-url}"
			shift 2
			;;
		--remote)
			UPSTREAM_REMOTE="${2:?missing value for --remote}"
			shift 2
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			echo "sync-upstream-pr: unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

if [ -z "$SYNC_BRANCH" ]; then
	echo "sync-upstream-pr: --branch is required" >&2
	usage >&2
	exit 2
fi

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if [ "$(git branch --show-current)" != "termux" ]; then
	echo "sync-upstream-pr: must run from the termux branch" >&2
	exit 2
fi

if [ -n "$(git status --porcelain)" ]; then
	echo "sync-upstream-pr: requires a clean termux checkout" >&2
git status --short >&2
	exit 2
fi

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
	git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

remote_ref="refs/remotes/${UPSTREAM_REMOTE}/${UPSTREAM_REF}"
case "$UPSTREAM_REF" in
	refs/*) remote_ref="$UPSTREAM_REF" ;;
esac

echo "sync-upstream-pr: fetching $UPSTREAM_REMOTE/$UPSTREAM_REF"
git fetch --no-tags "$UPSTREAM_REMOTE" "$UPSTREAM_REF:$remote_ref"
target=$(git rev-parse "$remote_ref")

if git merge-base --is-ancestor "$target" HEAD; then
	echo "sync-upstream-pr: already up to date"
	exit 10
fi

# The workflow owns this branch name and may refresh it on a later run.
git branch -D "$SYNC_BRANCH" >/dev/null 2>&1 || true
git switch --create "$SYNC_BRANCH" HEAD >/dev/null

if git -c user.name="omp-sync" -c user.email="omp-sync@localhost" \
	merge --no-ff --no-edit "$target"; then
	echo "sync-upstream-pr: prepared $SYNC_BRANCH"
	echo "sync-upstream-pr: upstream=$(git rev-parse --short "$target")"
	exit 0
fi

echo "sync-upstream-pr: CONFLICT — no sync branch will be published" >&2
git diff --name-only --diff-filter=U >&2
git merge --abort >/dev/null 2>&1 || true
git switch termux >/dev/null
git branch -D "$SYNC_BRANCH" >/dev/null 2>&1 || true
exit 1
