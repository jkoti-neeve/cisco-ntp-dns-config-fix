#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Neeve AI Dev Framework — Setup Script
# =============================================================================
# Pulls the framework into the current project directory.
#
# Usage:
#   1. Place this file in your project root (or copy it there)
#   2. Open a terminal in your project directory
#   3. Run: bash setup-framework.sh
#
# Works on: macOS, Linux, Windows (Git Bash / WSL)
# Prerequisites: git, GitHub access to kchristo-neeve/neeve-ai-dev-framework
# =============================================================================

REPO_URL="https://github.com/kchristo-neeve/neeve-ai-dev-framework.git"
FRAMEWORK_DIRS=(".ai" ".claude" ".agent")

# --- Resolve project directory (where this script lives) ---
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Cleanup trap: always remove temp dir on exit ---
TEMP_DIR=""
cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

# --- Preflight checks ---
echo "=== Neeve AI Dev Framework Setup ==="
echo ""

# Check git is installed
if ! command -v git &>/dev/null; then
  echo "ERROR: git is not installed."
  echo "  macOS:   brew install git"
  echo "  Linux:   sudo apt install git  (or your distro's package manager)"
  echo "  Windows: https://git-scm.com/download/win (includes Git Bash)"
  exit 1
fi

# Check GitHub authentication
if ! git ls-remote "$REPO_URL" HEAD &>/dev/null; then
  echo "ERROR: Cannot access the framework repository."
  echo ""
  echo "This is a private repo. You need GitHub authentication:"
  echo "  1. Install GitHub CLI: https://cli.github.com/"
  echo "  2. Run: gh auth login"
  echo "  3. Re-run this script"
  echo ""
  echo "Or configure SSH/HTTPS credentials for GitHub."
  exit 1
fi

echo "Project directory: $PROJECT_DIR"
echo ""

# --- Check for existing framework files ---
EXISTING=()
for dir in "${FRAMEWORK_DIRS[@]}"; do
  if [[ -d "$PROJECT_DIR/$dir" ]]; then
    EXISTING+=("$dir")
  fi
done

if [[ ${#EXISTING[@]} -gt 0 ]]; then
  echo "NOTE: Found existing framework directories: ${EXISTING[*]}"
  echo "      Existing files will NOT be overwritten."
  echo ""
fi

# --- Create temp directory ---
TEMP_DIR="$(mktemp -d)"

# --- Clone framework (sparse checkout — only framework dirs) ---
echo "[1/3] Pulling framework from GitHub..."
git clone --depth 1 --filter=blob:none --sparse \
  "$REPO_URL" "$TEMP_DIR/framework-pull" 2>&1 | tail -1
cd "$TEMP_DIR/framework-pull"
git sparse-checkout set "${FRAMEWORK_DIRS[@]}" 2>/dev/null
cd "$PROJECT_DIR"

echo "[2/3] Copying framework files..."

# --- Copy function: no-clobber across platforms ---
# cp -n behaves differently across OS versions, so we use a safe approach:
# only copy files that don't already exist in the destination.
copy_no_clobber() {
  local src="$1"
  local dest="$2"

  if [[ ! -d "$src" ]]; then
    return
  fi

  # Walk the source tree and copy files that don't exist at the destination
  cd "$src"
  find . -type f | while read -r file; do
    local target="$dest/$file"
    if [[ ! -f "$target" ]]; then
      mkdir -p "$(dirname "$target")"
      cp "$file" "$target"
    fi
  done
  cd "$PROJECT_DIR"
}

for dir in "${FRAMEWORK_DIRS[@]}"; do
  if [[ -d "$TEMP_DIR/framework-pull/$dir" ]]; then
    copy_no_clobber "$TEMP_DIR/framework-pull/$dir" "$PROJECT_DIR/$dir"
    echo "       $dir/"
  fi
done

# --- Also copy this setup script if not already present ---
if [[ -f "$TEMP_DIR/framework-pull/setup-framework.sh" ]] && [[ ! -f "$PROJECT_DIR/setup-framework.sh" ]]; then
  cp "$TEMP_DIR/framework-pull/setup-framework.sh" "$PROJECT_DIR/setup-framework.sh"
  echo "       setup-framework.sh"
fi

# Temp dir is cleaned up automatically by the trap

echo "[3/3] Done!"
echo ""
echo "=== Framework installed into: $PROJECT_DIR ==="
echo ""
echo "Next steps:"
echo "  1. Open this folder in your AI-powered IDE (Antigravity, Cursor, etc.)"
echo "  2. If using Claude Code / Antigravity, restart so slash commands are discovered"
echo "  3. Run:  /framework-init"
echo ""
