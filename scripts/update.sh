#!/usr/bin/env bash
set -euo pipefail

# Automated update script for Lark LPK project.
# Wraps the skill's lzc-release-update.sh with project-specific conveniences:
#   - Auto-detects upstream image from manifest comment
#   - Bumps version in package.yml (major/minor/patch or explicit)
#   - Checks upstream GitHub for latest release
#   - Optionally commits + tags in git
#   - Optionally publishes to app store

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILL_SCRIPT="${HOME}/.claude/skills/lazycat-app-publisher/scripts/lzc-release-update.sh"
PACKAGE_FILE="$PROJECT_DIR/package.yml"
MANIFEST_FILE="$PROJECT_DIR/lzc-manifest.yml"

usage() {
  cat <<'USAGE'
Usage: scripts/update.sh [options]

Automate Lark LPK version updates.

Options:
  <version>                    Explicit version (e.g. 0.10.0). Overrides --bump.
  --bump <major|minor|patch>   Auto-bump from current version. Default: patch.
  --check                      Only check for upstream updates, don't apply.
  --publish                    Publish to app store after build.
  --changelog <text>           Changelog text. Default: "更新到 <version>".
  --git                        Commit and tag after update.
  --no-build                   Update files without building LPK.
  --source-image <image>       Override upstream image (skip comment auto-detect).
  -h, --help                   Show this help.

Examples:
  scripts/update.sh --check                     # Check for new upstream release
  scripts/update.sh --bump patch                # Bump patch: 0.9.16 -> 0.9.17
  scripts/update.sh --bump minor                # Bump minor: 0.9.16 -> 0.10.0
  scripts/update.sh 0.10.0                      # Set explicit version
  scripts/update.sh 0.10.0 --publish --git      # Update, build, publish, commit+tag
  scripts/update.sh --bump patch --publish --git  # Bump, build, publish, commit+tag
USAGE
}

die() { echo "error: $*" >&2; exit 1; }
note() { echo "==> $*" >&2; }

# --- Parse current version from package.yml ---
current_version() {
  awk '/^version:/ {
    val = $2
    gsub(/[" ]/, "", val)
    print val
    exit
  }' "$PACKAGE_FILE"
}

# --- Bump version ---
bump_version() {
  local cur=$1 kind=$2
  local major minor patch
  IFS='.' read -r major minor patch <<< "$cur"
  case "$kind" in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "${major}.$((minor + 1)).0" ;;
    patch) echo "${major}.${minor}.$((patch + 1))" ;;
    *) die "unknown bump kind: $kind" ;;
  esac
}

# --- Extract upstream repo from manifest comment ---
upstream_from_comment() {
  awk '
    /^[[:space:]]*# [a-zA-Z0-9].*:[a-zA-Z0-9]/ {
      line = $0
      sub(/^[[:space:]]*#[[:space:]]*/, "", line)
      gsub(/[[:space:]]*$/, "", line)
      print line
      exit
    }
  ' "$MANIFEST_FILE"
}

# --- Extract GitHub owner/repo from comment or homepage ---
github_repo() {
  local comment
  comment=$(upstream_from_comment)
  # comment looks like: ghcr.io/owner/repo:v1.0.0  or  owner/repo:v1.0.0
  if [[ -n "$comment" ]]; then
    # Strip registry prefix and tag
    local ref=$comment
    ref=${ref#ghcr.io/}
    ref=${ref#docker.io/}
    ref=${ref#registry.*/}
    ref=${ref%:*}
    # If it looks like owner/repo
    if [[ "$ref" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
      echo "$ref"
      return 0
    fi
  fi
  # Fallback: homepage in package.yml
  awk '/^homepage:/ {
    url = $2
    gsub(/[" ]/, "", url)
    if (url ~ /github\.com\//) {
      sub(/.*github\.com\//, "", url)
      # Remove trailing slash and anything after repo (e.g. /issues)
      gsub(/\/+$/, "", url)
      # Extract owner/repo (first two path segments)
      n = split(url, parts, "/")
      if (n >= 2) print parts[1] "/" parts[2]
    }
  }' "$PACKAGE_FILE"
}

# --- Fetch latest version from GitHub (tries releases, then tags) ---
github_latest() {
  local repo=$1
  local latest=""

  # Try releases/latest first
  latest=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null |
    awk -F'"' '/"tag_name"/ { print $4; exit }' | sed 's/^v//')

  # Fallback: latest tag
  if [[ -z "$latest" ]]; then
    latest=$(curl -fsSL "https://api.github.com/repos/$repo/tags?per_page=1" 2>/dev/null |
      awk -F'"' '/"name"/ { print $4; exit }' | sed 's/^v//')
  fi

  echo "$latest"
}

# --- Check latest upstream release ---
check_upstream() {
  local repo
  repo=$(github_repo)
  [[ -n "$repo" ]] || die "cannot determine upstream GitHub repo from manifest comment or package.yml homepage"

  local cur_ver
  cur_ver=$(current_version)

  note "Checking upstream: github.com/$repo (current: v$cur_ver)"

  local latest
  latest=$(github_latest "$repo")

  if [[ -z "$latest" ]]; then
    echo "⚠  Cannot reach GitHub API for $repo (repo may be private or rate-limited)."
    echo "   Current version: v$cur_ver"
    echo "   Manual check: https://github.com/$repo/releases"
    return 2
  fi

  if [[ "$latest" == "$cur_ver" ]]; then
    echo "✅ Up-to-date: v$cur_ver"
    return 0
  else
    echo "🔄 Update available: v$cur_ver -> v$latest"
    echo "   Run: scripts/update.sh $latest"
    return 1
  fi
}

# --- Main ---
BUMP=""
CHECK_ONLY=0
PUBLISH=0
GIT_TAG=0
NO_BUILD=0
EXPLICIT_VERSION=""
SOURCE_IMAGE=""
CHANGELOG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bump) BUMP=${2:-patch}; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --publish) PUBLISH=1; shift ;;
    --git) GIT_TAG=1; shift ;;
    --no-build) NO_BUILD=1; shift ;;
    --source-image) SOURCE_IMAGE=${2:-}; shift 2 ;;
    --changelog) CHANGELOG=${2:-}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) EXPLICIT_VERSION=$1; shift ;;
  esac
done

# Check mode
if [[ "$CHECK_ONLY" == "1" ]]; then
  check_upstream
  exit $?
fi

# Determine target version
if [[ -n "$EXPLICIT_VERSION" ]]; then
  TARGET_VERSION="$EXPLICIT_VERSION"
elif [[ -n "$BUMP" ]]; then
  CUR=$(current_version)
  TARGET_VERSION=$(bump_version "$CUR" "$BUMP")
else
  die "specify a version or use --bump (major|minor|patch). See --help."
fi

CUR=$(current_version)
note "Version: v$CUR -> v$TARGET_VERSION"

# Build args for lzc-release-update.sh
[[ -f "$SKILL_SCRIPT" ]] || die "skill script not found: $SKILL_SCRIPT"

RELEASE_ARGS=("$TARGET_VERSION")
if [[ -n "$SOURCE_IMAGE" ]]; then
  RELEASE_ARGS+=(--source-image "$SOURCE_IMAGE")
fi
if [[ "$PUBLISH" == "1" ]]; then
  RELEASE_ARGS+=(--publish)
fi
if [[ -n "$CHANGELOG" ]]; then
  RELEASE_ARGS+=(--changelog "$CHANGELOG")
fi
if [[ "$NO_BUILD" == "1" ]]; then
  RELEASE_ARGS+=(--skip-build)
fi

note "Running: $SKILL_SCRIPT ${RELEASE_ARGS[*]}"
bash "$SKILL_SCRIPT" "${RELEASE_ARGS[@]}"

# Git commit + tag
if [[ "$GIT_TAG" == "1" ]]; then
  note "Committing and tagging v$TARGET_VERSION"
  cd "$PROJECT_DIR"
  git add package.yml lzc-manifest.yml
  git commit -m "bump $TARGET_VERSION"
  git tag -a "v$TARGET_VERSION" -m "Release v$TARGET_VERSION"
  note "Tagged v$TARGET_VERSION. Run 'git push && git push --tags' to push."
fi

note "Done. LPK: community.lazycat.app.lark-v${TARGET_VERSION}.lpk"
