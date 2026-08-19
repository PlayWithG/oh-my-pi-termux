#!/bin/sh
set -eu

# Safely synchronize the long-lived Termux branch with upstream OMP.
#
# Default mode is read-only: the merge is attempted in a disposable worktree
# so a conflict cannot dirty or rewrite the user's checkout. Use --apply only
# from a clean `termux` branch when a maintainer explicitly wants the merge.

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/can1357/oh-my-pi.git}"
UPSTREAM_REF="${UPSTREAM_REF:-main}"
MODE="check"

usage() {
	cat <<'EOF'
Usage: scripts/sync-upstream.sh [options]

Options:
  --check                 Fetch upstream and test the merge in a temporary worktree (default).
  --apply                 Apply the merge to the current `termux` branch.
  --upstream-ref <ref>    Upstream branch or tag (default: main).
  --upstream-url <url>    Upstream repository URL.
  --remote <name>         Git remote name (default: upstream).
  -h, --help              Show this help.

Examples:
  scripts/sync-upstream.sh --check --upstream-ref main
  scripts/sync-upstream.sh --check --upstream-ref v17.3.7
  scripts/sync-upstream.sh --apply --upstream-ref v17.3.7
EOF
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--check)
			MODE="check"
			shift
			;;
		--apply)
			MODE="apply"
			shift
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
			echo "Unknown option: $1" >&2
			usage >&2
			exit 2
			;;
	esac
done

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

if [ "$(git branch --show-current)" != "termux" ]; then
	echo "sync-upstream: must run from the termux branch" >&2
	exit 2
fi

if [ "$MODE" = "apply" ] && [ -n "$(git status --porcelain)" ]; then
	echo "sync-upstream: --apply requires a clean worktree" >&2
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

echo "sync-upstream: fetching $UPSTREAM_REMOTE/$UPSTREAM_REF"
git fetch --no-tags "$UPSTREAM_REMOTE" "$UPSTREAM_REF:$remote_ref"

target=$(git rev-parse "$remote_ref")
base=$(git merge-base HEAD "$target")
adapter_commits=$(git rev-list --count "$base..HEAD")
echo "sync-upstream: current=$(git rev-parse --short HEAD)"
echo "sync-upstream: upstream=$(git rev-parse --short "$target")"
echo "sync-upstream: merge-base=$(git rev-parse --short "$base")"
echo "sync-upstream: downstream commits since merge-base=$adapter_commits"

if [ "$MODE" = "apply" ]; then
	echo "sync-upstream: applying merge"
	git merge --no-ff "$target" -m "merge: synchronize OMP upstream $UPSTREAM_REF"
	echo "sync-upstream: merge applied; run native Termux gates before tagging"
	exit 0
fi

tmp_worktree=$(mktemp -d "${TMPDIR:-/tmp}/omp-sync.XXXXXX")
cleanup() {
	git worktree remove --force "$tmp_worktree" >/dev/null 2>&1 || true
	rmdir "$tmp_worktree" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git worktree add --detach "$tmp_worktree" HEAD >/dev/null
if git -C "$tmp_worktree" merge --no-commit --no-ff "$target"; then
	echo "sync-upstream: CLEAN — upstream can be merged without conflicts"
	echo "sync-upstream: changed files in candidate merge"
	git -C "$tmp_worktree" diff --stat HEAD
	git -C "$tmp_worktree" merge --abort >/dev/null 2>&1 || true
	exit 0
fi

echo "sync-upstream: CONFLICT — no files were changed in the original checkout" >&2
git -C "$tmp_worktree" diff --name-only --diff-filter=U >&2
git -C "$tmp_worktree" merge --abort >/dev/null 2>&1 || true
exit 1
