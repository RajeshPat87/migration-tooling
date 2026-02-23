#!/bin/bash
# =============================================================================
# migration-tooling/scripts/bootstrap.sh
# ONE-TIME SETUP — Run before starting migration
# Creates GitHub repos, sets secrets/variables, configures environments
# Mirrors existing ADO repos to GitHub for the first time
# =============================================================================

set -euo pipefail

GH_PAT="${GH_PAT:-}"
GH_ORG="${GH_ORG:-}"
ADO_PAT="${ADO_PAT:-}"
ADO_ORG="${ADO_ORG:-}"
ADO_PROJECT="${ADO_PROJECT:-}"

# Azure resource values (fill in yours)
ACR_NAME="${ACR_NAME:-migrationpocacr}"
ACR_LOGIN_SERVER="${ACR_LOGIN_SERVER:-migrationpocacr.azurecr.io}"
AKS_CLUSTER="${AKS_CLUSTER:-migration-poc-aks}"
AKS_RG="${AKS_RG:-migration-poc-rg}"
AZURE_CREDENTIALS="${AZURE_CREDENTIALS:-}"   # JSON: {"clientId":...}

SERVICES=("bmi-service" "unit-converter")

for V in GH_PAT GH_ORG ADO_PAT ADO_ORG ADO_PROJECT; do
  [[ -n "${!V:-}" ]] || { echo "❌ Required: $V"; exit 1; }
done

echo "╔════════════════════════════════════════════════════╗"
echo "║     Bootstrap: ADO → GitHub Migration Setup        ║"
echo "╠════════════════════════════════════════════════════╣"
echo "║  GH Org  : $GH_ORG"
echo "║  ADO     : $ADO_ORG / $ADO_PROJECT"
echo "╚════════════════════════════════════════════════════╝"

# ── Login to gh CLI ────────────────────────────────────────────────────────────
echo ""
echo "STEP 1: GitHub CLI login..."
echo "$GH_PAT" | gh auth login --with-token
echo "  ✅ GH CLI authenticated as: $(gh api /user -q .login)"

GH_ACCEPT="Accept: application/vnd.github.v3+json"
GH_AUTH="Authorization: Bearer $GH_PAT"
CT="Content-Type: application/json"

for SVC in "${SERVICES[@]}"; do
  echo ""
  echo "══════════════════════════════════════════"
  echo "  Setting up: $SVC"
  echo "══════════════════════════════════════════"

  # ── Create GH repo if it doesn't exist ────────────────────────────────────
  echo "  Creating GitHub repo (if needed)..."
  gh repo create "$GH_ORG/$SVC" \
    --private \
    --description "Migrated from ADO: $ADO_ORG/$ADO_PROJECT/$SVC" \
    2>/dev/null && echo "  ✅ Created: github.com/$GH_ORG/$SVC" || \
    echo "  ℹ️  Already exists: github.com/$GH_ORG/$SVC"

  API="https://api.github.com/repos/$GH_ORG/$SVC"

  # ── Set secrets ────────────────────────────────────────────────────────────
  echo "  Setting GitHub secrets..."
  gh secret set AZURE_CREDENTIALS   --body "$AZURE_CREDENTIALS"    --repo "$GH_ORG/$SVC" 2>/dev/null && echo "  ✅ Secret: AZURE_CREDENTIALS" || echo "  ⚠️  AZURE_CREDENTIALS — set manually"
  gh secret set ACR_NAME            --body "$ACR_NAME"             --repo "$GH_ORG/$SVC" && echo "  ✅ Secret: ACR_NAME"
  gh secret set ACR_LOGIN_SERVER    --body "$ACR_LOGIN_SERVER"     --repo "$GH_ORG/$SVC" && echo "  ✅ Secret: ACR_LOGIN_SERVER"
  gh secret set AKS_CLUSTER_NAME   --body "$AKS_CLUSTER"          --repo "$GH_ORG/$SVC" && echo "  ✅ Secret: AKS_CLUSTER_NAME"
  gh secret set AKS_RESOURCE_GROUP --body "$AKS_RG"               --repo "$GH_ORG/$SVC" && echo "  ✅ Secret: AKS_RESOURCE_GROUP"
  gh secret set GH_PAT             --body "$GH_PAT"               --repo "$GH_ORG/$SVC" && echo "  ✅ Secret: GH_PAT"

  # ── Set variables (non-secret) ─────────────────────────────────────────────
  echo "  Setting GitHub variables..."
  VARS_API="$API/actions/variables"
  set_var() {
    local NAME=$1 VALUE=$2
    curl -s -X POST "$VARS_API" \
      -H "$GH_AUTH" -H "$GH_ACCEPT" -H "$CT" \
      -d "{\"name\":\"$NAME\",\"value\":\"$VALUE\"}" > /dev/null 2>&1 || \
    curl -s -X PATCH "$VARS_API/$NAME" \
      -H "$GH_AUTH" -H "$GH_ACCEPT" -H "$CT" \
      -d "{\"name\":\"$NAME\",\"value\":\"$VALUE\"}" > /dev/null
    echo "  ✅ Var: $NAME=$VALUE"
  }

  # Start at Phase 1 (mirror only)
  set_var "MIGRATION_PHASE" "1"
  set_var "ADO_STATUS"      "active"
  set_var "GH_ORG"          "$GH_ORG"

  # ── Create environments ────────────────────────────────────────────────────
  echo "  Creating environments..."
  for ENV_NAME in staging production; do
    curl -s -X PUT "$API/environments/$ENV_NAME" \
      -H "$GH_AUTH" -H "$GH_ACCEPT" -H "$CT" \
      -d '{}' > /dev/null
    echo "  ✅ Environment: $ENV_NAME"
  done

  # Add branch protection to production
  curl -s -X PUT "$API/environments/production" \
    -H "$GH_AUTH" -H "$GH_ACCEPT" -H "$CT" \
    -d '{"deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}' \
    > /dev/null
  echo "  ✅ Branch protection: production → main only"

  # ── Initial mirror from ADO ────────────────────────────────────────────────
  echo "  Performing initial mirror from ADO..."
  WORK=$(mktemp -d)
  ADO_URL="https://$ADO_ORG:$ADO_PAT@dev.azure.com/$ADO_ORG/$ADO_PROJECT/_git/$SVC"
  GH_URL="https://x-access-token:$GH_PAT@github.com/$GH_ORG/$SVC.git"

  if git clone --mirror "$ADO_URL" "$WORK/$SVC" 2>/dev/null; then
    cd "$WORK/$SVC"
    git remote add github "$GH_URL"
    git push github --mirror --force 2>/dev/null && \
      echo "  ✅ Initial mirror complete: $SVC" || \
      echo "  ⚠️  Mirror push failed — ADO repo may not exist yet"
    cd -
    rm -rf "$WORK"
  else
    echo "  ⚠️  ADO clone failed — repo may not exist yet. Create it and re-run."
  fi
done

echo ""
echo "╔════════════════════════════════════════════════════╗"
echo "║           ✅ Bootstrap Complete                     ║"
echo "╠════════════════════════════════════════════════════╣"
echo "║  Phase    : 1 (Mirror) — ADO is sole CI/CD         ║"
echo "║  Next     : Add ADO pipelines MirrorToGitHub stage ║"
echo "║  Then     : Set MIGRATION_PHASE=2 to enter Shadow  ║"
echo "╚════════════════════════════════════════════════════╝"
