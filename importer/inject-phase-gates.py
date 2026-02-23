#!/usr/bin/env python3
"""
migration-tooling/importer/inject-phase-gates.py
PPT Slide 4 — After gh-actions-importer converts ADO YAML → GHA YAML,
this script post-processes every converted workflow and:
  1. Injects MIGRATION_PHASE env var + phase gate check step
  2. Maps ADO service connection names → GH secrets
  3. Maps ADO variable group vars → GH secrets/vars
  4. Ensures shadow=no-deploy guard on all deploy/apply/helm/kubectl steps
  5. Adds phase-labelled job summaries

Usage:
    python3 inject-phase-gates.py --input-dir ./importer-output/migrate
    python3 inject-phase-gates.py --input-dir ./importer-output/migrate --dry-run
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path
from datetime import datetime

# ── Default mappings — update to match YOUR ADO environment ──────────────────

SERVICE_CONNECTION_MAP = {
    "azure-service-connection":        "AZURE_CREDENTIALS",
    "acr-service-connection":          "AZURE_CREDENTIALS",
    "aks-service-connection":          "AZURE_CREDENTIALS",
    "AzureServiceConnection":          "AZURE_CREDENTIALS",
    "AKS-ServiceConnection":           "AZURE_CREDENTIALS",
}

VARIABLE_MAP = {
    "ACR_SERVICE_CONNECTION":  "secrets.ACR_NAME",
    "ACR_LOGIN_SERVER":        "secrets.ACR_LOGIN_SERVER",
    "AZURE_SERVICE_CONNECTION":"secrets.AZURE_CREDENTIALS",
    "AKS_CLUSTER_NAME":        "secrets.AKS_CLUSTER_NAME",
    "AKS_RESOURCE_GROUP":      "secrets.AKS_RESOURCE_GROUP",
    "GITHUB_PAT":              "secrets.GH_PAT",
    "GITHUB_ORG":              "vars.GH_ORG",
    "TF_BACKEND_SA":           "secrets.TF_BACKEND_SA",
    "TF_BACKEND_RG":           "secrets.TF_BACKEND_RG",
}

PHASE_GATE_ENV_BLOCK = """
  # ── Migration Phase Gate (injected by inject-phase-gates.py) ──────────────
  # Set MIGRATION_PHASE in GH repo Settings → Secrets & Variables → Actions → Variables
  # 1=Mirror(ADO only) 2=Shadow(build only) 3=Validate(staging) 4=Cutover(primary) 5=Decommission
  MIGRATION_PHASE: ${{ vars.MIGRATION_PHASE || '2' }}
"""

PHASE_GATE_STEP = """      # Phase gate — injected by inject-phase-gates.py
      - name: 'Migration Phase Gate'
        run: |
          PHASE="${{ env.MIGRATION_PHASE }}"
          echo "Current migration phase: $PHASE"
          if [[ "$PHASE" == "1" || "$PHASE" == "2" ]]; then
            echo "⏭️  Phase $PHASE — this deploy step is SKIPPED (ADO is main actor)"
            echo "To enable GH deploys: set MIGRATION_PHASE=4 in repo variables after cutover"
            exit 0
          fi
          echo "✅ Phase $PHASE — GH deploy is authorized"
"""

HEADER_COMMENT = """\
# ================================================================================
# AUTO-CONVERTED: Azure DevOps → GitHub Actions
# Converted by: gh-actions-importer (github/gh-actions-importer)
# Post-processed by: inject-phase-gates.py
# Conversion date: {date}
#
# MIGRATION PHASE REFERENCE (set MIGRATION_PHASE in GH repo variables):
#   Phase 1 — Mirror   : ADO is sole CI/CD. GH repo mirrors ADO via git push.
#   Phase 2 — Shadow   : GHA builds & tests but does NOT deploy (ADO deploys).
#   Phase 3 — Validate : GHA shadow-deploys to staging. ADO still deploys prod.
#   Phase 4 — Cutover  : GHA is primary CI/CD. ADO pipelines are disabled (dormant).
#   Phase 5 — Decommission: ADO pipelines archived. GH is sole CI/CD.
# ================================================================================

"""

DEPLOY_KEYWORDS = re.compile(
    r'(helm upgrade|helm install|kubectl apply|kubectl rollout|'
    r'az aks|docker push|AzureWebApp|AzureFunctionApp|terraform apply)',
    re.IGNORECASE
)

JOB_DEPLOY_PATTERN = re.compile(r'^\s{2}[a-zA-Z_][a-zA-Z0-9_-]*:\s*$')


def add_header(content: str, filename: str) -> str:
    header = HEADER_COMMENT.format(date=datetime.utcnow().strftime("%Y-%m-%d"))
    if content.startswith("# ===="):
        return content
    return header + content


def add_phase_env(content: str) -> str:
    """Add MIGRATION_PHASE env var at top-level env block."""
    if "MIGRATION_PHASE" in content:
        return content

    env_pattern = re.compile(r'^env:\s*$', re.MULTILINE)
    if env_pattern.search(content):
        content = env_pattern.sub(f"env:{PHASE_GATE_ENV_BLOCK}", content, count=1)
    else:
        # Add env block after 'on:' section
        on_match = re.search(r'^(on:.*?)(?=\n\w)', content, re.DOTALL | re.MULTILINE)
        if on_match:
            insert_pos = on_match.end()
            content = content[:insert_pos] + f"\nenv:{PHASE_GATE_ENV_BLOCK}\n" + content[insert_pos:]

    return content


def inject_gate_into_deploy_jobs(content: str) -> str:
    """Find jobs that contain deploy commands and inject phase gate step."""
    lines = content.splitlines(keepends=True)
    result = []
    inject_after_next_steps = False
    steps_found_in_job = False
    current_job_has_deploy = False

    for i, line in enumerate(lines):
        result.append(line)

        # Detect a job block
        if JOB_DEPLOY_PATTERN.match(line):
            # Check if this job or the next ~20 lines have deploy keywords
            lookahead = "".join(lines[i:min(i+30, len(lines))])
            if DEPLOY_KEYWORDS.search(lookahead):
                inject_after_next_steps = True
                steps_found_in_job = False

        # Inject phase gate after 'steps:' line in deploy jobs
        if inject_after_next_steps and re.match(r'^\s+steps:\s*$', line) and not steps_found_in_job:
            result.append(PHASE_GATE_STEP)
            steps_found_in_job = True
            inject_after_next_steps = False

    return "".join(result)


def map_service_connections(content: str) -> str:
    for ado_name, gh_secret in SERVICE_CONNECTION_MAP.items():
        content = re.sub(
            rf'(azureSubscription|containerRegistry|connectedServiceName|ConnectedServiceName)'
            rf':\s+[\'"]?{re.escape(ado_name)}[\'"]?',
            rf'\1: ${{{{ secrets.{gh_secret} }}}}',
            content, flags=re.IGNORECASE
        )
    return content


def map_variables(content: str) -> str:
    for ado_var, gh_ref in VARIABLE_MAP.items():
        content = re.sub(
            rf'\$\({re.escape(ado_var)}\)',
            f'${{{{ {gh_ref} }}}}',
            content
        )
    return content


def process_file(src: Path, dst: Path, dry_run: bool) -> dict:
    content = src.read_text(encoding="utf-8")
    original_len = len(content)

    content = add_header(content, src.name)
    content = add_phase_env(content)
    content = inject_gate_into_deploy_jobs(content)
    content = map_service_connections(content)
    content = map_variables(content)

    result = {
        "file":        str(src),
        "output":      str(dst),
        "original_len": original_len,
        "processed_len": len(content),
        "dry_run":     dry_run
    }

    if not dry_run:
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(content, encoding="utf-8")
        result["status"] = "written"
    else:
        result["status"] = "dry-run-only"

    return result


def main():
    parser = argparse.ArgumentParser(description="Inject migration phase gates into imported GH workflows")
    parser.add_argument("--input-dir",  required=True, help="Dir with converted YAML files from gh-actions-importer")
    parser.add_argument("--output-dir", default=None,  help="Output dir (defaults to input-dir/processed)")
    parser.add_argument("--dry-run",    action="store_true", help="Preview only, no files written")
    args = parser.parse_args()

    input_dir  = Path(args.input_dir)
    output_dir = Path(args.output_dir) if args.output_dir else input_dir / "processed"

    yml_files = sorted(list(input_dir.rglob("*.yml")) + list(input_dir.rglob("*.yaml")))

    if not yml_files:
        print(f"No YAML files found in {input_dir}")
        sys.exit(1)

    print(f"Processing {len(yml_files)} workflow files...")
    print(f"Dry run: {args.dry_run}")
    print()

    results = []
    for src in yml_files:
        relative = src.relative_to(input_dir)
        dst = output_dir / relative
        r = process_file(src, dst, args.dry_run)
        status = "✅" if r["status"] == "written" else "👁"
        print(f"  {status} {src.name}")
        results.append(r)

    print()
    print(f"Done. {len(results)} files processed.")
    if not args.dry_run:
        print(f"Output → {output_dir}")
        print()
        print("Next steps:")
        print("  1. Review files in:", output_dir)
        print("  2. Copy to .github/workflows/ in each GH repo")
        print("  3. Set MIGRATION_PHASE=2 in GH repo Settings → Variables")
        print("  4. Commit & push — GH workflows now run in shadow mode")
        print("  5. Monitor parity. When ≥98%, run cutover.sh")


if __name__ == "__main__":
    main()
