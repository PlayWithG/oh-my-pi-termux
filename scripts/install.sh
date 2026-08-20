#!/bin/sh
set -e

# OMP Coding Agent Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/PlayWithG/oh-my-pi-termux/termux/scripts/install.sh | sh
#
# Options:
#   --source       Install via bun (installs bun if needed)
#   --binary       Always install prebuilt binary
#   --ref <ref>    Install specific tag/commit/branch
#   -r <ref>       Shorthand for --ref

REPO="PlayWithG/oh-my-pi-termux"
PACKAGE="@oh-my-pi/pi-coding-agent"
INSTALL_DIR="${PI_INSTALL_DIR:-$HOME/.local/bin}"
MIN_BUN_VERSION="1.3.14"

# Parse arguments
MODE=""
REF=""
while [ $# -gt 0 ]; do
    case "$1" in
        --source)
            MODE="source"
            shift
            ;;
        --binary)
            MODE="binary"
            shift
            ;;
        --ref)
            shift
            if [ -z "$1" ]; then
                echo "Missing value for --ref"
                exit 1
            fi
            REF="$1"
            shift
            ;;
        --ref=*)
            REF="${1#*=}"
            if [ -z "$REF" ]; then
                echo "Missing value for --ref"
                exit 1
            fi
            shift
            ;;
        -r)
            shift
            if [ -z "$1" ]; then
                echo "Missing value for -r"
                exit 1
            fi
            REF="$1"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# If a ref is provided, default to source install
if [ -n "$REF" ] && [ -z "$MODE" ]; then
    MODE="source"
fi

# Check if bun is available
has_bun() {
    command -v bun >/dev/null 2>&1
}

# Normalized host architecture (x64|arm64). On macOS this uses
# `sysctl hw.optional.arm64` so it stays correct inside a Rosetta session,
# where `uname -m` reports the translated x86_64.
host_arch() {
    if [ "$(uname -s)" = "Darwin" ]; then
        if [ "$(sysctl -in hw.optional.arm64 2>/dev/null || /usr/sbin/sysctl -in hw.optional.arm64 2>/dev/null)" = "1" ]; then
            echo "arm64"
        else
            echo "x64"
        fi
        return
    fi
    case "$(uname -m)" in
        x86_64|amd64)  echo "x64" ;;
        arm64|aarch64) echo "arm64" ;;
        *)             uname -m ;;
    esac
}

# Bun's own architecture (x64|arm64), or empty when it can't be determined.
bun_arch() {
    bun -e 'process.stdout.write(process.arch)' 2>/dev/null
}

# True when Bun's architecture matches the host. If Bun's arch can't be read,
# assume a match rather than block the install.
bun_arch_matches_host() {
    ba="$(bun_arch)"
    [ -z "$ba" ] && return 0
    [ "$ba" = "$(host_arch)" ]
}

version_ge() {
    current="$1"
    minimum="$2"

    current_major="${current%%.*}"
    current_rest="${current#*.}"
    current_minor="${current_rest%%.*}"
    current_patch="${current_rest#*.}"
    current_patch="${current_patch%%.*}"

    minimum_major="${minimum%%.*}"
    minimum_rest="${minimum#*.}"
    minimum_minor="${minimum_rest%%.*}"
    minimum_patch="${minimum_rest#*.}"
    minimum_patch="${minimum_patch%%.*}"

    if [ "$current_major" -ne "$minimum_major" ]; then
        [ "$current_major" -gt "$minimum_major" ]
        return $?
    fi

    if [ "$current_minor" -ne "$minimum_minor" ]; then
        [ "$current_minor" -gt "$minimum_minor" ]
        return $?
    fi

    [ "$current_patch" -ge "$minimum_patch" ]
}

require_bun_version() {
    version_raw=$(bun --version 2>/dev/null || true)
    if [ -z "$version_raw" ]; then
        echo "Failed to read bun version"
        exit 1
    fi

    version_clean=${version_raw%%-*}
    if ! version_ge "$version_clean" "$MIN_BUN_VERSION"; then
        echo "Bun ${MIN_BUN_VERSION} or newer is required. Current version: ${version_clean}"
        echo "Upgrade Bun at https://bun.sh/docs/installation"
        exit 1
    fi
}

# Check if git is available
has_git() {
    command -v git >/dev/null 2>&1
}

# Keep Bun's global bin directory usable without changing the user's shell
# configuration. Invalid BUN_INSTALL values are corrected only in this process.
prepare_bun_install() {
    requested_bun_install="${BUN_INSTALL:-}"
    bun_install_valid=0
    if [ -n "$requested_bun_install" ] &&
        [ -d "$requested_bun_install" ] &&
        [ -w "$requested_bun_install" ] &&
        bun_install_absolute=$(CDPATH='' cd -- "$requested_bun_install" 2>/dev/null && pwd -P); then
        if [ -n "$bun_install_absolute" ]; then
            export BUN_INSTALL="$bun_install_absolute"
            if mkdir -p "$BUN_INSTALL/bin" && [ -w "$BUN_INSTALL/bin" ]; then
                bun_install_valid=1
            fi
        fi
    fi

    if [ "$bun_install_valid" -eq 0 ]; then
        export BUN_INSTALL="$HOME/.bun"
        if [ -n "$requested_bun_install" ]; then
            echo "BUN_INSTALL is not a writable directory; using $BUN_INSTALL for this install."
        fi
    fi

    if ! mkdir -p "$BUN_INSTALL/bin"; then
        echo "Failed to create Bun's global bin directory: $BUN_INSTALL/bin"
        exit 1
    fi
    if [ ! -w "$BUN_INSTALL/bin" ]; then
        echo "Bun's global bin directory is not writable: $BUN_INSTALL/bin"
        exit 1
    fi

    export PATH="$BUN_INSTALL/bin:$PATH"
}

# Install bun
install_bun() {
    echo "Installing bun..."
    prepare_bun_install
    if command -v bash >/dev/null 2>&1; then
        curl -fsSL https://bun.sh/install | bash
    else
        echo "bash not found; attempting install with sh..."
        curl -fsSL https://bun.sh/install | sh
    fi
    require_bun_version
}

# Check if git-lfs is available
has_git_lfs() {
    command -v git-lfs >/dev/null 2>&1
}

require_android_bun() {
    if has_bun; then
        return 0
    fi

    echo "A native Android Bun is required for the Termux source install."
    echo "Install it in Termux with: pkg install bun"
    echo "If that package is unavailable, install another native Bun for Android/arm64."
    exit 1
}

# Install via bun
install_via_bun() {
    echo "Installing via bun..."
    prepare_bun_install
    if [ -n "$REF" ]; then
        if ! has_git; then
            echo "git is required for --ref when installing from source"
            exit 1
        fi

        TMP_DIR="$(mktemp -d)"
        trap 'rm -rf "$TMP_DIR"' EXIT

        if git clone --depth 1 --branch "$REF" "https://github.com/${REPO}.git" "$TMP_DIR" >/dev/null 2>&1; then
            :
        else
            git clone "https://github.com/${REPO}.git" "$TMP_DIR"
            (cd "$TMP_DIR" && git checkout "$REF")
        fi

        # Pull LFS files
        if has_git_lfs; then
            (cd "$TMP_DIR" && git lfs pull)
        fi

        if [ ! -d "$TMP_DIR/packages/coding-agent" ]; then
            echo "Expected package at ${TMP_DIR}/packages/coding-agent"
            exit 1
        fi

        bun install -g "$TMP_DIR/packages/coding-agent" || {
            echo "Failed to install from source"
            exit 1
        }
    else
        bun install -g "$PACKAGE" || {
            echo "Failed to install $PACKAGE"
            exit 1
        }
    fi
    echo ""
    echo "✓ Installed omp via bun"
    echo "Run 'omp' to get started!"
}

# Return success only for a checkout cloned from the repository managed by this
# installer. Refusing other repositories prevents PI_SOURCE_DIR typos from
# modifying arbitrary directories.
managed_source_remote() {
    case "$1" in
        https://github.com/${REPO}|https://github.com/${REPO}.git|git@github.com:${REPO}|git@github.com:${REPO}.git|ssh://git@github.com/${REPO}|ssh://git@github.com/${REPO}.git)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

android_checkout_ref() {
    android_ref="$1"

    if git -C "$ANDROID_SOURCE_DIR" ls-remote --exit-code --heads origin "refs/heads/$android_ref" >/dev/null 2>&1; then
        if ! git -C "$ANDROID_SOURCE_DIR" fetch --prune --tags origin "refs/heads/$android_ref:refs/remotes/origin/$android_ref"; then
            echo "Android source branch was not found after fetching: $android_ref"
            exit 1
        fi
        if git -C "$ANDROID_SOURCE_DIR" show-ref --verify --quiet "refs/heads/$android_ref"; then
            if ! git -C "$ANDROID_SOURCE_DIR" checkout "$android_ref"; then
                echo "Failed to checkout Android source ref: $android_ref"
                exit 1
            fi
            if ! git -C "$ANDROID_SOURCE_DIR" merge --ff-only "origin/$android_ref"; then
                echo "Android source checkout has diverged from origin/$android_ref"
                exit 1
            fi
        else
            if ! git -C "$ANDROID_SOURCE_DIR" checkout --track "origin/$android_ref"; then
                echo "Failed to checkout Android source ref: $android_ref"
                exit 1
            fi
        fi
        return
    fi

    if git -C "$ANDROID_SOURCE_DIR" ls-remote --exit-code --tags origin "refs/tags/$android_ref" >/dev/null 2>&1; then
        if ! git -C "$ANDROID_SOURCE_DIR" fetch --prune --tags origin "+refs/tags/$android_ref:refs/tags/$android_ref"; then
            echo "Android source tag was not found after fetching: $android_ref"
            exit 1
        fi
        if ! git -C "$ANDROID_SOURCE_DIR" checkout --detach "refs/tags/$android_ref"; then
            echo "Failed to checkout Android source ref: $android_ref"
            exit 1
        fi
        return
    fi

    if git -C "$ANDROID_SOURCE_DIR" fetch origin "$android_ref" &&
        git -C "$ANDROID_SOURCE_DIR" cat-file -e FETCH_HEAD^{commit} 2>/dev/null; then
        if ! git -C "$ANDROID_SOURCE_DIR" checkout --detach FETCH_HEAD; then
            echo "Failed to checkout Android source ref: $android_ref"
            exit 1
        fi
        return
    fi

    echo "Android source ref was not found after fetching: $android_ref"
    exit 1
}

android_default_branch() {
    if ! android_remote_head=$(git -C "$ANDROID_SOURCE_DIR" ls-remote --symref origin HEAD); then
        echo "Failed to determine the default branch for the Android source checkout"
        exit 1
    fi
    ANDROID_DEFAULT_BRANCH=$(printf '%s\n' "$android_remote_head" | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p')
    if [ -z "$ANDROID_DEFAULT_BRANCH" ]; then
        echo "The Android source remote did not report a default branch"
        exit 1
    fi
}

cleanup_android_staging() {
    android_cleanup_status=0
    if [ "${android_source_new:-0}" -eq 1 ] &&
        [ -n "${ANDROID_SOURCE_DIR:-}" ] &&
        [ "$ANDROID_SOURCE_DIR" != "${android_source_target:-}" ]; then
        if ! rm -rf "$ANDROID_SOURCE_DIR"; then
            echo "Failed to clean the Android source staging checkout: $ANDROID_SOURCE_DIR" >&2
            android_cleanup_status=1
        fi
    fi
    return "$android_cleanup_status"
}

prepare_android_checkout() {
    ANDROID_SOURCE_DIR="${PI_SOURCE_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/omp-src}"
    while [ "$ANDROID_SOURCE_DIR" != "/" ] && [ "${ANDROID_SOURCE_DIR%/}" != "$ANDROID_SOURCE_DIR" ]; do
        ANDROID_SOURCE_DIR=${ANDROID_SOURCE_DIR%/}
    done
    android_current_dir=$(CDPATH='' pwd -P)
    android_current_git_root=$(git -C "$android_current_dir" rev-parse --show-toplevel 2>/dev/null || true)
    if [ -n "${PI_SOURCE_DIR:-}" ] && [ "$ANDROID_SOURCE_DIR" = "." ]; then
        echo "PI_SOURCE_DIR must point to a separate managed checkout, not the current working directory: ."
        exit 1
    fi
    android_source_parent=$(dirname -- "$ANDROID_SOURCE_DIR")
    android_source_name=$(basename -- "$ANDROID_SOURCE_DIR")

    if ! mkdir -p "$android_source_parent"; then
        echo "Failed to create the Android source parent directory: $android_source_parent"
        exit 1
    fi
    android_source_parent=$(CDPATH='' cd -- "$android_source_parent" && pwd -P)
    ANDROID_SOURCE_DIR="$android_source_parent/$android_source_name"

    if [ -e "$ANDROID_SOURCE_DIR" ]; then
        android_source_dir_real=$(CDPATH='' cd -- "$ANDROID_SOURCE_DIR" && pwd -P)
        if [ "$android_source_dir_real" = "$android_current_dir" ] ||
            { [ -n "$android_current_git_root" ] && [ "$android_source_dir_real" = "$android_current_git_root" ]; }; then
            echo "PI_SOURCE_DIR must point to a separate managed checkout, not the current working directory or its git checkout: $ANDROID_SOURCE_DIR"
            exit 1
        fi
    fi

    if [ -L "$ANDROID_SOURCE_DIR" ]; then
        echo "PI_SOURCE_DIR must not be a symlink: $ANDROID_SOURCE_DIR"
        exit 1
    fi

    android_source_new=0
    android_source_target="$ANDROID_SOURCE_DIR"
    trap cleanup_android_staging 0
    trap 'exit 1' 1 2 3 15
    if [ -e "$ANDROID_SOURCE_DIR" ]; then
        if [ ! -d "$ANDROID_SOURCE_DIR" ]; then
            echo "PI_SOURCE_DIR is not a directory: $ANDROID_SOURCE_DIR"
            exit 1
        fi

        if ! android_source_top=$(git -C "$ANDROID_SOURCE_DIR" rev-parse --show-toplevel); then
            echo "PI_SOURCE_DIR is not a managed git checkout: $ANDROID_SOURCE_DIR"
            exit 1
        fi
        android_source_top=$(CDPATH='' cd -- "$android_source_top" && pwd -P)
        android_source_dir_real=$(CDPATH='' cd -- "$ANDROID_SOURCE_DIR" && pwd -P)
        if [ "$android_source_top" != "$android_source_dir_real" ]; then
            echo "PI_SOURCE_DIR must be the root of a git checkout: $ANDROID_SOURCE_DIR"
            exit 1
        fi

        if ! android_origin=$(git -C "$ANDROID_SOURCE_DIR" config --get remote.origin.url); then
            echo "The Android source checkout has no origin remote: $ANDROID_SOURCE_DIR"
            exit 1
        fi
        if ! managed_source_remote "$android_origin"; then
            echo "The Android source checkout origin is not $REPO: $android_origin"
            exit 1
        fi

        if ! android_status=$(git -C "$ANDROID_SOURCE_DIR" status --porcelain); then
            echo "Failed to inspect the Android source checkout: $ANDROID_SOURCE_DIR"
            exit 1
        fi
        if [ -n "$android_status" ]; then
            echo "Android source checkout has local changes; refusing to update: $ANDROID_SOURCE_DIR"
            printf '%s\n' "$android_status"
            exit 1
        fi
    else
        android_source_new=1
        ANDROID_SOURCE_DIR="$ANDROID_SOURCE_DIR.install.$$"
        if [ -e "$ANDROID_SOURCE_DIR" ] || [ -L "$ANDROID_SOURCE_DIR" ]; then
            echo "Temporary Android source staging path already exists: $ANDROID_SOURCE_DIR"
            exit 1
        fi
        echo "Cloning Android source checkout to $android_source_target..."
        if [ -n "$REF" ]; then
            if git clone --depth 1 --branch "$REF" "https://github.com/${REPO}.git" "$ANDROID_SOURCE_DIR"; then
                :
            else
                echo "Ref $REF is not a direct clone branch/tag; retrying with a full checkout."
                if [ -e "$ANDROID_SOURCE_DIR" ] || [ -L "$ANDROID_SOURCE_DIR" ]; then
                    rm -rf "$ANDROID_SOURCE_DIR"
                fi
                if ! git clone "https://github.com/${REPO}.git" "$ANDROID_SOURCE_DIR"; then
                    echo "Failed to clone the Android source checkout"
                    if [ -e "$ANDROID_SOURCE_DIR" ] || [ -L "$ANDROID_SOURCE_DIR" ]; then
                        rm -rf "$ANDROID_SOURCE_DIR"
                    fi
                    exit 1
                fi
            fi
        else
            if ! git clone --depth 1 --single-branch "https://github.com/${REPO}.git" "$ANDROID_SOURCE_DIR"; then
                echo "Failed to clone the Android source checkout"
                if [ -e "$ANDROID_SOURCE_DIR" ] || [ -L "$ANDROID_SOURCE_DIR" ]; then
                    rm -rf "$ANDROID_SOURCE_DIR"
                fi
                exit 1
            fi
        fi
    fi

    if [ "$android_source_new" -eq 0 ]; then
        if ! git -C "$ANDROID_SOURCE_DIR" fetch --prune --tags origin; then
            echo "Failed to update the Android source checkout"
            exit 1
        fi
    fi

    if [ -n "$REF" ]; then
        android_checkout_ref "$REF"
    else
        android_default_branch
        android_checkout_ref "$ANDROID_DEFAULT_BRANCH"
    fi

    if has_git_lfs; then
        if ! git -C "$ANDROID_SOURCE_DIR" lfs pull; then
            echo "Failed to pull Git LFS files for the Android source checkout"
            exit 1
        fi
    fi

    if [ ! -d "$ANDROID_SOURCE_DIR/packages/coding-agent" ]; then
        echo "Expected package at $ANDROID_SOURCE_DIR/packages/coding-agent"
        if [ "$android_source_new" -eq 1 ]; then
            rm -rf "$ANDROID_SOURCE_DIR"
        fi
        exit 1
    fi

    if [ "$android_source_new" -eq 1 ]; then
        if [ -e "$android_source_target" ] || [ -L "$android_source_target" ]; then
            echo "PI_SOURCE_DIR appeared while cloning; refusing to replace it: $android_source_target"
            rm -rf "$ANDROID_SOURCE_DIR"
            exit 1
        fi
        if ! mv "$ANDROID_SOURCE_DIR" "$android_source_target"; then
            echo "Failed to persist the Android source checkout at $android_source_target"
            rm -rf "$ANDROID_SOURCE_DIR"
            exit 1
        fi
        android_source_new=0
        ANDROID_SOURCE_DIR="$android_source_target"
    fi
}

normalize_android_bun_shebangs() {
    # Bun rewrites workspace bin entrypoints to its absolute path on Termux.
    # Restore the repository's portable shebang so setup leaves no local diff.
    for android_script in \
        packages/coding-agent/src/cli.ts \
        packages/metaharness/src/server.ts \
        packages/mnemopi/src/cli.ts \
        packages/stats/src/index.ts; do
        android_script_path="$ANDROID_SOURCE_DIR/$android_script"
        if [ ! -f "$android_script_path" ]; then
            continue
        fi

        android_expected_shebang=$(git -C "$ANDROID_SOURCE_DIR" show "HEAD:$android_script" | sed -n '1p')
        android_current_shebang=$(sed -n '1p' "$android_script_path")
        if [ "$android_expected_shebang" = "#!/usr/bin/env bun" ]; then
            case "$android_current_shebang" in
                "#!"*bun)
                    android_expected_mode=$(git -C "$ANDROID_SOURCE_DIR" ls-tree -l HEAD -- "$android_script" | awk '{print $1}')
                    android_shebang_tmp="$android_script_path.omp-install.$$"
                    if ! sed '1s|.*|#!/usr/bin/env bun|' "$android_script_path" > "$android_shebang_tmp"; then
                        rm -f "$android_shebang_tmp"
                        echo "Failed to normalize Bun's generated shebang: $android_script"
                        exit 1
                    fi
                    if ! mv "$android_shebang_tmp" "$android_script_path"; then
                        rm -f "$android_shebang_tmp"
                        echo "Failed to persist the normalized Bun shebang: $android_script"
                        exit 1
                    fi
                    case "$android_expected_mode" in
                        100755)
                            if ! chmod 755 "$android_script_path"; then
                                echo "Failed to preserve the executable Bun script: $android_script"
                                exit 1
                            fi
                            ;;
                        *)
                            if ! chmod 644 "$android_script_path"; then
                                echo "Failed to preserve the Bun script mode: $android_script"
                                exit 1
                            fi
                            ;;
                    esac
                    ;;
            esac
        fi
    done
}

install_android_source() {
    echo "Installing Android source checkout via Bun..."
    require_android_bun
    if ! has_git; then
        echo "git is required for the native Android source install"
        exit 1
    fi
    require_bun_version
    if ! android_bun_platform=$(bun_platform); then
        echo "Failed to determine the native Bun platform"
        exit 1
    fi
    android_bun_arch=$(bun_arch)
    if [ "$android_bun_platform/$android_bun_arch" != "android/arm64" ]; then
        echo "Only native Android/arm64 Bun is supported; this Bun reports '$android_bun_platform/$android_bun_arch'."
        exit 1
    fi
    if [ "$(host_arch)" != "arm64" ]; then
        echo "Only an Android arm64 host is supported; this host reports '$(host_arch)'."
        exit 1
    fi

    prepare_bun_install
    prepare_android_checkout

    echo "Building and linking OMP from $ANDROID_SOURCE_DIR..."
    android_setup_status=0
    if (CDPATH='' cd -- "$ANDROID_SOURCE_DIR" &&
        bun install &&
        bun run build:native &&
        bun --cwd=packages/coding-agent link); then
        :
    else
        android_setup_status=$?
    fi
    normalize_android_bun_shebangs
    if [ "$android_setup_status" -ne 0 ]; then
        echo "Failed to build and link OMP from the Android source checkout"
        exit "$android_setup_status"
    fi
    # build:native regenerates this checked-in declaration with deterministic
    # reorder churn on Bun/Android. Restore it before the clean-check gate so a
    # failed update never changes the managed checkout or the active launcher.
    git -C "$ANDROID_SOURCE_DIR" restore -- packages/natives/native/index.d.ts
    if ! android_status=$(git -C "$ANDROID_SOURCE_DIR" status --porcelain); then
        echo "Failed to inspect the Android source checkout after setup"
        exit 1
    fi
    if [ -n "$android_status" ]; then
        echo "Android setup left unexpected local changes in the managed checkout:"
        printf '%s\n' "$android_status"
        exit 1
    fi

    if ! (CDPATH='' cd -- "$ANDROID_SOURCE_DIR" && sh scripts/link-omp.sh); then
        echo "Failed to link the verified Android omp launcher"
        exit 1
    fi

    android_global_bin=$(bun pm -g bin 2>/dev/null || true)
    case "$android_global_bin" in
        /*) ;;
        *) android_global_bin="$BUN_INSTALL/bin" ;;
    esac
    ANDROID_GLOBAL_BIN="$android_global_bin"
    ANDROID_LAUNCHER="$ANDROID_GLOBAL_BIN/omp"
    if [ ! -L "$ANDROID_LAUNCHER" ]; then
        echo "The Android omp launcher is not the global Bun symlink: $ANDROID_LAUNCHER"
        exit 1
    fi
    if ! command -v readlink >/dev/null 2>&1; then
        echo "readlink is required to verify the Android omp launcher: $ANDROID_LAUNCHER"
        exit 1
    fi
    android_launcher_resolved="$ANDROID_LAUNCHER"
    while [ -L "$android_launcher_resolved" ]; do
        if ! android_launcher_link=$(readlink "$android_launcher_resolved"); then
            echo "Failed to resolve the Android omp launcher: $ANDROID_LAUNCHER"
            exit 1
        fi
        case "$android_launcher_link" in
            /*) android_launcher_resolved="$android_launcher_link" ;;
            *) android_launcher_resolved="$(dirname -- "$android_launcher_resolved")/$android_launcher_link" ;;
        esac
    done
    if ! android_launcher_resolved_dir=$(CDPATH='' cd -- "$(dirname -- "$android_launcher_resolved")" && pwd -P); then
        echo "The Android omp launcher target does not exist: $ANDROID_LAUNCHER"
        exit 1
    fi
    android_launcher_resolved="$android_launcher_resolved_dir/$(basename -- "$android_launcher_resolved")"
    if ! android_expected_launcher_dir=$(CDPATH='' cd -- "$ANDROID_SOURCE_DIR/packages/coding-agent/scripts" && pwd -P); then
        echo "The Android omp launcher target directory is missing: $ANDROID_SOURCE_DIR/packages/coding-agent/scripts"
        exit 1
    fi
    if [ "$android_launcher_resolved" != "$android_expected_launcher_dir/omp" ]; then
        echo "The Android omp launcher does not target this checkout: $ANDROID_LAUNCHER"
        echo "Expected: $android_expected_launcher_dir/omp"
        echo "Resolved: $android_launcher_resolved"
        exit 1
    fi
    if [ ! -x "$ANDROID_LAUNCHER" ]; then
        echo "The Android omp launcher is not executable: $ANDROID_LAUNCHER"
        exit 1
    fi

    if [ "$(sed -n '1p' "$ANDROID_LAUNCHER")" != "#!/bin/sh" ]; then
        echo "The Android omp launcher is not a POSIX shell wrapper: $ANDROID_LAUNCHER"
        exit 1
    fi
    if grep -q '/usr/bin/env' "$ANDROID_LAUNCHER"; then
        echo "The Android omp launcher must not depend on /usr/bin/env: $ANDROID_LAUNCHER"
        exit 1
    fi

    echo "Verifying Android omp launcher..."
    if ! (CDPATH='' cd -- "$(dirname -- "$ANDROID_SOURCE_DIR")" &&
        "$ANDROID_LAUNCHER" --version &&
        "$ANDROID_LAUNCHER" --help >/dev/null &&
        "$ANDROID_LAUNCHER" --smoke-test); then
        echo "The Android omp launcher failed verification"
        exit 1
    fi

    echo ""
    echo "✓ Installed omp from Android source at $ANDROID_SOURCE_DIR"
    case ":$PATH:" in
        *":$ANDROID_GLOBAL_BIN:"*) echo "Run 'omp' to get started!" ;;
        *) echo "Add $ANDROID_GLOBAL_BIN to your PATH, then run 'omp'" ;;
    esac
}

# Report the runtime platform when the host is Termux/Android. Prefer Bun's
# platform identity because native Bun builds expose `android`; the fallback
# uses Termux's own environment/utility markers without assuming a device path.
bun_platform() {
    bun -e 'process.stdout.write(process.platform)' 2>/dev/null
}

host_platform() {
    if has_bun; then
        if runtime_platform=$(bun_platform); then
            :
        else
            runtime_platform=""
        fi
        if [ "$runtime_platform" = "android" ]; then
            echo "android"
            return
        fi
    fi
    if command -v getprop >/dev/null 2>&1 || { [ -n "${PREFIX:-}" ] && [ -x "$PREFIX/bin/termux-info" ]; }; then
        echo "android"
        return
    fi
    uname -s
}

# Install binary from GitHub releases
install_binary() {
    # Detect platform
    OS="$(host_platform)"
    ARCH="$(host_arch)"

    case "$OS" in
        android)
            echo "Prebuilt Android binaries are not published; install from source with --source."
            exit 1
            ;;
        Linux)  PLATFORM="linux" ;;
        Darwin) PLATFORM="darwin" ;;
        *)      echo "Unsupported OS: $OS"; exit 1 ;;
    esac

    case "$ARCH" in
        x64|arm64) ;;
        *)         echo "Unsupported architecture: $ARCH"; exit 1 ;;
    esac

    if [ "$PLATFORM" = "linux" ]; then
        if [ -f /etc/alpine-release ] || { command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; }; then
            PLATFORM="linux-musl"
        fi
    fi

    BINARY="omp-${PLATFORM}-${ARCH}"
    # Get release tag
    if [ -n "$REF" ]; then
        echo "Fetching release $REF..."
        if RELEASE_JSON=$(curl -fsSL --connect-timeout 10 --max-time 60 "https://api.github.com/repos/${REPO}/releases/tags/${REF}"); then
            LATEST=$(echo "$RELEASE_JSON" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
        else
            echo "Release tag not found: $REF"
            echo "For branch/commit installs, use --source with --ref."
            exit 1
        fi
    else
        echo "Fetching latest release..."
        RELEASE_JSON=$(curl -fsSL --connect-timeout 10 --max-time 60 "https://api.github.com/repos/${REPO}/releases/latest")
        LATEST=$(echo "$RELEASE_JSON" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
    fi

    if [ -z "$LATEST" ]; then
        echo "Failed to fetch release tag"
        exit 1
    fi
    echo "Using version: $LATEST"

    mkdir -p "$INSTALL_DIR"
    # Download binary
    BINARY_URL="https://github.com/${REPO}/releases/download/${LATEST}/${BINARY}"
    echo "Downloading ${BINARY}..."
    curl -fsSL --connect-timeout 10 --speed-limit 1024 --speed-time 30 "$BINARY_URL" -o "${INSTALL_DIR}/omp"
    chmod +x "${INSTALL_DIR}/omp"

    # Verify the freshly installed binary can actually start before reporting
    # success. Bun's musl-target binaries link libstdc++/libgcc dynamically,
    # which stock Alpine/musl systems do not ship, so the download succeeds while
    # the binary exits 127 with relocation errors. Never claim success for a
    # binary that cannot run.
    if ! SMOKE_OUTPUT="$("${INSTALL_DIR}/omp" --version 2>&1)"; then
        echo ""
        echo "✗ omp was downloaded to ${INSTALL_DIR}/omp but cannot start:"
        echo "$SMOKE_OUTPUT" | sed 's/^/    /'
        if [ "$PLATFORM" = "linux-musl" ]; then
            echo ""
            echo "The musl build links libstdc++/libgcc dynamically. Install them, then re-run 'omp':"
            if command -v apk >/dev/null 2>&1; then
                echo "    apk add libstdc++ libgcc"
            else
                echo "    (install the libstdc++ and libgcc runtime packages for your distro)"
            fi
        fi
        exit 1
    fi

    echo ""
    echo "✓ Installed omp to ${INSTALL_DIR}/omp"

    # Check if in PATH
    case ":$PATH:" in
        *":$INSTALL_DIR:"*) echo "Run 'omp' to get started!" ;;
        *) echo "Add ${INSTALL_DIR} to your PATH, then run 'omp'" ;;
    esac
}

# Main logic
case "$MODE" in
    source)
        if [ "$(host_platform)" = "android" ]; then
            require_android_bun
            install_android_source
        else
            if ! has_bun; then
                install_bun
            fi
            require_bun_version
            if ! bun_arch_matches_host; then
                echo "Error: bun reports architecture '$(bun_arch)' but this host is '$(host_arch)'."
                echo "Installing from source with this bun would produce a mismatched binary"
                echo "(e.g. x86_64 under Rosetta on Apple Silicon), causing slow startup and AVX warnings."
                echo "Install a native bun for your architecture, or re-run without --source to fetch the prebuilt $(host_arch) binary."
                exit 1
            fi
            install_via_bun
        fi
        ;;
    binary)
        install_binary
        ;;
    *)
        # Default: use bun only when it matches the host architecture, otherwise
        # fall back to the prebuilt binary so Rosetta bun can't force an x86_64 build.
        if [ "$(host_platform)" = "android" ]; then
            require_android_bun
            install_android_source
        elif has_bun && bun_arch_matches_host; then
            require_bun_version
            install_via_bun
        else
            if has_bun; then
                echo "Detected bun with architecture '$(bun_arch)' on a '$(host_arch)' host; using the prebuilt binary instead."
            fi
            install_binary
        fi
        ;;
esac
