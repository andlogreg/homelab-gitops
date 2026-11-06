#!/usr/bin/env python3
"""Check every PrometheusRule with promtool, and run the alert rules' unit tests.

promtool reads plain rule files, not PrometheusRule manifests. So this writes each manifest's
spec.groups into a scratch tree at the manifest's own path, runs `promtool check rules` over all
of them, and runs `promtool test rules` over every test in monitoring/rule-tests/. A test names
the manifests it loads in `rule_files`, relative to itself. A `*.test.py` writes its test file
into the directory it is given, for cases easier to compute than to write out.

Only files in git's index count, as that is what a commit holds: `git add` a new test to run it.

Usage: run_rule_tests.py   (wired as a pre-commit hook)
Exit 0 if every rule parses and every test passes, 1 otherwise.
"""
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
TESTS = Path("monitoring/rule-tests")


def tracked(*patterns):
    """Paths in git's index that match the pathspecs, relative to ROOT."""
    out = subprocess.run(["git", "ls-files", "-z", "--", *patterns], cwd=ROOT,
                         capture_output=True, text=True, check=True).stdout
    return [Path(p) for p in out.split("\0") if p]


def promtool():
    """The promtool on PATH, if it is the version mise.toml pins.

    Every call runs from ROOT, because a mise shim picks its version by the working directory.
    """
    pinned = tomllib.loads((ROOT / "mise.toml").read_text())["tools"]["promtool"]
    path = shutil.which("promtool")
    found = ""
    if path:
        run = subprocess.run([path, "--version"], cwd=ROOT, capture_output=True, text=True)
        found = " ".join(run.stdout.split()[2:3])
    if found != pinned:
        sys.exit(f"promtool {pinned} is pinned in mise.toml, but PATH has {found or 'none'}: "
                 "run `mise install`.")
    return path


def main():
    tool = promtool()
    with tempfile.TemporaryDirectory() as scratch:
        scratch = Path(scratch)
        rules = tracked("*prometheusrule-*.yaml")
        for path in rules:
            docs = [d for d in yaml.safe_load_all((ROOT / path).read_text())
                    if d and d.get("kind") == "PrometheusRule"]
            if not docs:
                sys.exit(f"{path} holds no PrometheusRule.")
            groups = [g for d in docs for g in d["spec"]["groups"]]
            (scratch / path).parent.mkdir(parents=True, exist_ok=True)
            (scratch / path).write_text(yaml.safe_dump({"groups": groups}, sort_keys=False))

        tests = scratch / TESTS
        tests.mkdir(parents=True, exist_ok=True)
        for path in tracked(f"{TESTS}/*.test.yaml"):
            shutil.copy(ROOT / path, tests)
        for path in tracked(f"{TESTS}/*.test.py"):
            if subprocess.run([sys.executable, ROOT / path, tests]).returncode:
                sys.exit(f"{path} did not write its tests.")
        names = sorted(p.name for p in tests.glob("*.test.yaml"))
        if not names:
            sys.exit(f"No rule tests in {TESTS}/.")
        for name in names:
            for rule_file in yaml.safe_load((tests / name).read_text())["rule_files"]:
                if not (tests / rule_file).is_file():
                    sys.exit(f"{TESTS / name} loads {rule_file}, which is not a PrometheusRule "
                             "manifest in git.")

        failed = subprocess.run([tool, "check", "rules", *(str(scratch / p) for p in rules)],
                                cwd=ROOT).returncode != 0
        # One file per run, because promtool's report does not say which file failed.
        for name in names:
            print(f"\nUnit testing {TESTS / name}", flush=True)
            failed |= subprocess.run([tool, "test", "rules", str(tests / name)],
                                     cwd=ROOT).returncode != 0
    if failed:
        print("\nBlocked: a PrometheusRule does not parse, or a rule test failed (above).")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
