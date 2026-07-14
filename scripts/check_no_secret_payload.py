#!/usr/bin/env python3
"""Fail if any committed Kubernetes Secret carries an inline payload.

In this repo no Secret material — plaintext OR encrypted — belongs in git: every
secret lives in Azure Key Vault and is pulled in at runtime via an ExternalSecret
(the ESO model). This structural guard complements gitleaks: gitleaks scans for
credential-shaped *values*, while this refuses any `kind: Secret` whose `data` or
`stringData` is populated at all, regardless of encoding or entropy (a base64 or
SOPS-encrypted payload slips past pattern/entropy scanners but is caught here).

Usage: check_no_secret_payload.py FILE [FILE ...]   (wired as a pre-commit hook)
Exit 0 if clean, 1 if any populated Secret manifest is found.
"""
import sys

import yaml


def _fields(node):
    """Top-level key(str) -> value node for a YAML mapping node."""
    return {getattr(k, "value", None): v for k, v in node.value}


def _is_populated(node):
    """True if the node holds at least one real entry/value."""
    if node is None:
        return False
    if isinstance(node, yaml.MappingNode):
        return len(node.value) > 0
    if isinstance(node, yaml.ScalarNode):
        return node.value not in (None, "", "null", "~")
    return bool(getattr(node, "value", None))


def check_file(path):
    """Return a list of (line, field) offences for a single file."""
    offences = []
    try:
        with open(path, "r") as fh:
            docs = list(yaml.compose_all(fh))
    except (yaml.YAMLError, OSError):
        return offences  # YAML validity is check-yaml's job, not ours
    for doc in docs:
        if not isinstance(doc, yaml.MappingNode):
            continue
        fields = _fields(doc)
        kind = fields.get("kind")
        if kind is None or getattr(kind, "value", None) != "Secret":
            continue
        for field in ("data", "stringData"):
            value = fields.get(field)
            if _is_populated(value):
                offences.append((value.start_mark.line + 1, field))
    return offences


def main(argv):
    failed = False
    for path in argv[1:]:
        for line, field in check_file(path):
            print(
                f"{path}:{line}: committed Secret has a populated '{field}' — move it "
                f"to Key Vault + an ExternalSecret (no Secret payload belongs in git)"
            )
            failed = True
    if failed:
        print(
            "\nBlocked: Kubernetes Secret manifests must not carry inline "
            "data/stringData in this repo."
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
