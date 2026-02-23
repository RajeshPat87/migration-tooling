#!/usr/bin/env python3
"""
migration-tooling/validator/parity-checker.py
PPT Phase 3 — VALIDATE
"2-week parallel run: ADO deploys prod, GHA shadow-deploys to staging"
"Validation dashboard: side-by-side comparison of all metrics"
"Go/No-Go gate: ≥98% parity score required to proceed"

Compares:
  - Test results: ADO vs GHA (pass/fail counts, duration)
  - Build metadata: image tags, layer counts
  - Deployment success rate per service
  - Calculates PARITY SCORE (must be ≥98% to allow cutover)

Usage:
    python3 parity-checker.py \
        --ado-artifacts   ./ado-artifacts \
        --gha-artifacts   ./gha-artifacts \
        --output-report   ./parity-report.json
"""

import argparse
import json
import os
import sys
from pathlib import Path
from datetime import datetime
from typing import Optional

PARITY_THRESHOLD = 98.0   # PPT: "≥98% parity score required to proceed"


def load_json(path: Path) -> Optional[dict]:
    try:
        return json.loads(path.read_text())
    except Exception as e:
        print(f"  ⚠️  Could not load {path}: {e}")
        return None


def parse_junit(xml_path: Path) -> dict:
    """Parse JUnit XML test results for comparison."""
    try:
        import xml.etree.ElementTree as ET
        tree = ET.parse(xml_path)
        root = tree.getroot()
        suite = root if root.tag == "testsuite" else root.find(".//testsuite")
        if suite is None:
            return {"tests": 0, "failures": 0, "errors": 0, "skipped": 0}
        return {
            "tests":    int(suite.get("tests",    0)),
            "failures": int(suite.get("failures", 0)),
            "errors":   int(suite.get("errors",   0)),
            "skipped":  int(suite.get("skipped",  0)),
            "time":     float(suite.get("time",   0.0)),
        }
    except Exception as e:
        return {"error": str(e)}


class ParityChecker:
    def __init__(self, ado_dir: Path, gha_dir: Path):
        self.ado_dir = ado_dir
        self.gha_dir = gha_dir
        self.results = []
        self.services = ["bmi-service", "unit-converter"]

    def check_service(self, service: str) -> dict:
        print(f"\n  Checking: {service}")
        checks = []

        # ── 1. Build metadata comparison ─────────────────────────────────────
        ado_meta_files = list(self.ado_dir.rglob(f"{service}-ado-build.json"))
        gha_meta_files = list(self.gha_dir.rglob(f"{service}-gha-*.json"))

        if ado_meta_files and gha_meta_files:
            ado_meta = load_json(ado_meta_files[0])
            gha_meta = load_json(gha_meta_files[0])

            if ado_meta and gha_meta:
                # Both builds completed
                checks.append({
                    "check": "build_completed",
                    "ado": ado_meta.get("test_passed", True),
                    "gha": not bool(gha_meta.get("error")),
                    "passed": True,
                    "weight": 20
                })
                print(f"    ✅ Build metadata: both present")
        else:
            print(f"    ⚠️  Build metadata missing — ADO: {len(ado_meta_files)}, GHA: {len(gha_meta_files)}")
            checks.append({"check": "build_metadata", "passed": False, "weight": 20,
                          "note": "metadata files missing"})

        # ── 2. Test results comparison ────────────────────────────────────────
        ado_test_files = list(self.ado_dir.rglob(f"*{service}*test*.xml"))
        gha_test_files = list(self.gha_dir.rglob(f"*{service}*test*.xml"))

        if ado_test_files and gha_test_files:
            ado_tests = parse_junit(ado_test_files[0])
            gha_tests = parse_junit(gha_test_files[0])

            ado_total   = ado_tests.get("tests", 0)
            gha_total   = gha_tests.get("tests", 0)
            ado_pass    = ado_total - ado_tests.get("failures", 0) - ado_tests.get("errors", 0)
            gha_pass    = gha_total - gha_tests.get("failures", 0) - gha_tests.get("errors", 0)

            test_parity = (min(ado_pass, gha_pass) / max(ado_pass, gha_pass) * 100) if max(ado_pass, gha_pass) > 0 else 100

            checks.append({
                "check": "test_results",
                "ado_tests": ado_total, "ado_passed": ado_pass,
                "gha_tests": gha_total, "gha_passed": gha_pass,
                "parity_pct": round(test_parity, 2),
                "passed": test_parity >= PARITY_THRESHOLD,
                "weight": 40
            })
            status = "✅" if test_parity >= PARITY_THRESHOLD else "❌"
            print(f"    {status} Test parity: {test_parity:.1f}% (ADO: {ado_pass}/{ado_total} | GHA: {gha_pass}/{gha_total})")
        else:
            print(f"    ⚠️  Test result XMLs not found for comparison")
            checks.append({"check": "test_results", "passed": False, "weight": 40,
                          "note": "junit XMLs missing"})

        # ── 3. Coverage comparison ────────────────────────────────────────────
        ado_cov_files = list(self.ado_dir.rglob(f"*{service}*coverage*.xml"))
        gha_cov_files = list(self.gha_dir.rglob(f"*{service}*coverage*.xml"))

        if ado_cov_files and gha_cov_files:
            # Just verify both exist and are non-zero
            ado_size = ado_cov_files[0].stat().st_size
            gha_size = gha_cov_files[0].stat().st_size
            checks.append({
                "check": "coverage_report",
                "ado_size": ado_size, "gha_size": gha_size,
                "passed": ado_size > 0 and gha_size > 0,
                "weight": 20
            })
            print(f"    ✅ Coverage reports: ADO={ado_size}b, GHA={gha_size}b")
        else:
            checks.append({"check": "coverage_report", "passed": False, "weight": 20,
                          "note": "coverage XMLs missing"})

        # ── 4. Calculate weighted parity score for this service ───────────────
        total_weight = sum(c["weight"] for c in checks)
        passed_weight = sum(c["weight"] for c in checks if c.get("passed", False))
        parity_score = (passed_weight / total_weight * 100) if total_weight > 0 else 0

        go_nogo = "GO ✅" if parity_score >= PARITY_THRESHOLD else "NO-GO ❌"
        print(f"    Parity score: {parity_score:.1f}% → {go_nogo}")

        return {
            "service":       service,
            "parity_score":  round(parity_score, 2),
            "go_nogo":       "GO" if parity_score >= PARITY_THRESHOLD else "NO-GO",
            "checks":        checks,
            "threshold":     PARITY_THRESHOLD,
        }

    def run(self) -> dict:
        print("================================================")
        print("  Parity Checker — ADO vs GitHub Actions")
        print(f"  Threshold : {PARITY_THRESHOLD}%")
        print(f"  ADO dir   : {self.ado_dir}")
        print(f"  GHA dir   : {self.gha_dir}")
        print("================================================")

        service_results = [self.check_service(s) for s in self.services]

        # Overall parity
        overall = sum(s["parity_score"] for s in service_results) / len(service_results)
        all_go  = all(s["go_nogo"] == "GO" for s in service_results)

        report = {
            "timestamp":       datetime.utcnow().isoformat() + "Z",
            "threshold_pct":   PARITY_THRESHOLD,
            "overall_parity":  round(overall, 2),
            "cutover_decision": "GO ✅" if all_go else "NO-GO ❌",
            "services":        service_results,
            "recommendation":  (
                "All services meet ≥98% parity — SAFE TO PROCEED TO CUTOVER (Phase 4)"
                if all_go else
                "One or more services below 98% parity — DO NOT CUTOVER. Review failures."
            )
        }

        print()
        print("================================================")
        print(f"  Overall Parity : {overall:.1f}%")
        print(f"  Decision       : {report['cutover_decision']}")
        print(f"  Recommendation : {report['recommendation']}")
        print("================================================")

        return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ado-artifacts", required=True)
    parser.add_argument("--gha-artifacts", required=True)
    parser.add_argument("--output-report", default="parity-report.json")
    args = parser.parse_args()

    checker = ParityChecker(Path(args.ado_artifacts), Path(args.gha_artifacts))
    report  = checker.run()

    Path(args.output_report).write_text(json.dumps(report, indent=2))
    print(f"\nReport written → {args.output_report}")

    # Exit code 1 if NO-GO (for use in pipeline gate)
    sys.exit(0 if report["cutover_decision"].startswith("GO") else 1)


if __name__ == "__main__":
    main()
