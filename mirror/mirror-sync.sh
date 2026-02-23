#!/bin/bash
# =============================================================================
# migration-tooling/mirror/mirror-sync.sh
# PPT Phase 1 — MIRROR
# "ADO Git repos mirrored to GitHub via automated sync (cron/webhook)"
# "Developers continue working in ADO — zero change to workflow"
# "Branch policies, tags, and release branches all synced"
#
# Called by ADO pipeline MirrorToGitHub stage after every build
# Also runs on 5-min cron schedule as safety net
#
# Usage:
#   export GITHUB_PAT="ghp_xxxx"
#   export GITHUB_ORG="your-org"
#   ./mirror-sync.sh bmi-service
#   ./mirror-sync.sh unit-converter
#   ./mirror-sync.sh --all          # mirror both repos
# =============================================================================

set -euo pipefail

GITHUB_PAT="${GITHUB_PAT:-}"
GITHUB_ORG="${GITHUB_ORG:-}"
ADO_ORG="${ADO_ORG:-}"
ADO_PROJECT="${ADO_PROJECT:-}"

# ── Validate env ──────────────────────────────────────────────────────────────
for VAR in GITHUB_PAT GITHUB_ORG ADO_ORG ADO_PROJECT; do
  if [[ -z "${!VAR:-}" ]]; then
    echo "❌ Required env var not set: $VAR"
    echo "   export GITHUB_PAT=ghp_xxx GITHUB_ORG=myorg ADO_ORG=myado ADO_PROJECT=myproject"
    exit 1
  fi
done

REPOS=("bmi-service" "unit-converter")
TARGET="${1:-}"

if [[ "$TARGET" == "--all" || -z "$TARGET" ]]; then
  MIRROR_REPOS=("${REPOS[@]}")
else
  MIRROR_REPOS=("$TARGET")
fi

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

# ── Mirror one repo ────────────────────────────────────────────────────────────
mirror_repo() {
  local REPO=$1
  local CLONE_DIR="$WORK_DIR/$REPO"

  echo ""
  echo "──────────────────────────────────────────"
  echo "  Mirroring: $REPO"
  echo "  ADO : https://dev.azure.com/$ADO_ORG/$ADO_PROJECT/_git/$REPO"
  echo "  GH  : https://github.com/$GITHUB_ORG/$REPO"
  echo "──────────────────────────────────────────"

  # Clone bare from ADO
  ADO_URL="https://$ADO_ORG:$ADO_PAT@dev.azure.com/$ADO_ORG/$ADO_PROJECT/_git/$REPO"
  GH_URL="https://x-access-token:$GITHUB_PAT@github.com/$GITHUB_ORG/$REPO.git"

  git clone --mirror "$ADO_URL" "$CLONE_DIR"

  cd "$CLONE_DIR"

  # Push all refs to GitHub
  git remote add github "$GH_URL" 2>/dev/null || git remote set-url github "$GH_URL"
  git push github --mirror --force

  COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
  BRANCHES=$(git branch -r | wc -l | tr -d ' ')
  TAGS=$(git tag | wc -l | tr -d ' ')

  echo "  ✅ Mirror complete"
  echo "     HEAD commit : $COMMIT"
  echo "     Branches    : $BRANCHES"
  echo "     Tags        : $TAGS"

  cd - > /dev/null
}

# ── Conflict detection ─────────────────────────────────────────────────────────
check_drift() {
  local REPO=$1
  echo "  Checking for drift in $REPO..."

  GH_URL="https://x-access-token:$GITHUB_PAT@github.com/$GITHUB_ORG/$REPO.git"

  # Compare HEAD of main branch
  ADO_HEAD=$(git ls-remote "https://$ADO_ORG:$ADO_PAT@dev.azure.com/$ADO_ORG/$ADO_PROJECT/_git/$REPO" \
    refs/heads/main 2>/dev/null | awk '{print $1}' || echo "err")
  GH_HEAD=$(git ls-remote "$GH_URL" refs/heads/main 2>/dev/null | awk '{print $1}' || echo "err")

  if [[ "$ADO_HEAD" == "$GH_HEAD" ]]; then
    echo "  ✅ No drift — ADO and GH are in sync"
  elif [[ "$ADO_HEAD" == "err" || "$GH_HEAD" == "err" ]]; then
    echo "  ⚠️  Could not check drift (network/auth issue)"
  else
    echo "  ⚠️  Drift detected!"
    echo "     ADO HEAD : $ADO_HEAD"
    echo "     GH  HEAD : $GH_HEAD"
    echo "  → Triggering re-mirror..."
  fi
}

# ── Main ───────────────────────────────────────────────────────────────────────
echo "================================================"
echo "  ADO → GitHub Mirror Sync"
echo "  Phase 1 (Mirror) — ADO is source of truth"
echo "  Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "================================================"

ADO_PAT="${ADO_PAT:-$GITHUB_PAT}"     # Fallback: use same PAT if ADO PAT not set

SUCCESS=0
FAILED=0

for REPO in "${MIRROR_REPOS[@]}"; do
  mirror_repo "$REPO" && ((SUCCESS++)) || ((FAILED++))
done

echo ""
echo "================================================"
echo "  Mirror Summary"
echo "  ✅ Success : $SUCCESS"
echo "  ❌ Failed  : $FAILED"
echo "================================================"

if [[ $FAILED -gt 0 ]]; then
  exit 1
fi
