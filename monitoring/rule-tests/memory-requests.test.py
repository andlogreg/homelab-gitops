#!/usr/bin/env python3
"""Write memory-requests.test.yaml, the unit tests for ContainerMemoryAboveRequest, into DIR.

Python rather than YAML, because the cases need exact per-minute patterns over 30 h. Series as
production scrapes them: cAdvisor's working set per cgroup (a restarted container leaves one series
per cgroup id) and kube-state-metrics' requests, one sample a minute. Production evaluates rules
every 60 s. Times are minutes from 0; every run lasts 30 h.

Usage: memory-requests.test.py DIR   (run by scripts/run_rule_tests.py)
"""
import os
import sys

import yaml

T = 1800
MI = 1024 * 1024
R, R2 = 100 * MI, 150 * MI            # requests: 100 Mi, raised to 150 Mi
A, B, H, S = 120 * MI, 80 * MI, 60 * MI, 300 * MI   # above, below, half, spike
G2 = 2048 * MI


def enc(tokens):
    """Per-minute tokens (int, None for no sample, 'stale') -> promtool's compact notation."""
    out, i = [], 0
    while i < len(tokens):
        j = i
        while j < len(tokens) and tokens[j] == tokens[i] and tokens[i] != "stale":
            j += 1
        j = max(j, i + 1)
        v, n = tokens[i], j - i
        if v is None:
            out.append(f"_x{n}" if n > 1 else "_")
        elif v == "stale":
            out.append("stale")
        else:
            out.append(f"{v}x{n - 1}" if n > 1 else f"{v}")
        i = j
    return " ".join(out)


def run(*segs):
    """Segments of (value, minutes); value None leaves minutes without a sample."""
    tokens = []
    for v, n in segs:
        tokens += [v] * n
    assert len(tokens) <= T + 1, len(tokens)
    return enc(tokens)


def ws(ns, pod, ctr, values, cid="c1"):
    return {"series": f'container_memory_working_set_bytes{{namespace="{ns}",pod="{pod}",container="{ctr}",'
                      f'id="/kubepods/burstable/pod-{pod}/{cid}",image="img",name="{cid}"}}', "values": values}


def req(ns, pod, ctr, values, resource="memory"):
    unit = "byte" if resource == "memory" else "core"
    return {"series": f'kube_pod_container_resource_requests{{namespace="{ns}",pod="{pod}",container="{ctr}",'
                      f'resource="{resource}",unit="{unit}",uid="uid-{pod}"}}', "values": values}


def alert(ns, pod, ctr, at="120MiB", request="100MiB"):
    desc = (f"Its working set has been above its memory request for at least 90% of the last day, "
            f"at {at} or more. The request is {request}. Re-measure it and raise the request: "
            f"resource-requests.md says how.")
    return {"exp_labels": {"severity": "warning", "namespace": ns, "pod": pod, "container": ctr},
            "exp_annotations": {"summary": f"{ns}/{pod}: container {ctr} has outgrown its memory request",
                                "description": desc}}


def at(t, *alerts):
    h, m = divmod(t, 60)
    return {"eval_time": f"{h}h{m}m", "alertname": "ContainerMemoryAboveRequest", "exp_alerts": list(alerts)}


def flat(v):
    return run((v, T + 1))


tests = []


def test(comment, series, evals):
    tests.append({"name": comment, "interval": "1m", "input_series": series, "alert_rule_test": evals})


# 1. Sustained excess: 120 Mi against 100 Mi from the start. Judged once 264 five-minute steps
#    exist (21h55m), pending an hour, firing at 22h55m, and still firing at 29h.
test("sustained excess", [ws("app", "app-0", "app", flat(A)), req("app", "app-0", "app", flat(R))],
     [at(22 * 60 + 54), at(22 * 60 + 55, alert("app", "app-0", "app")), at(29 * 60, alert("app", "app-0", "app"))])

# 2. Brief excess, after the containers are old enough to be judged: a 3-hour spike to 300 Mi,
#    and a job that holds 120 Mi for its last 8 hours. Neither is above for 90% of a day. startup-0
#    starts at 130% for its first 3 hours, as many did after D40's restarts.
test("brief spike, an 8-hour job and startup memory",
     [ws("spike", "spike-0", "app", run((B, 1380), (S, 180), (B, T + 1 - 1560))), req("spike", "spike-0", "app", flat(R)),
      ws("job", "job-0", "app", run((B, 1320), (A, T + 1 - 1320))), req("job", "job-0", "app", flat(R)),
      ws("startup", "startup-0", "app", run((130 * MI, 180), (B, T + 1 - 180))), req("startup", "startup-0", "app", flat(R))],
     [at(24 * 60), at(26 * 60), at(29 * 60), at(30 * 60)])

# 3. No memory request: 2 GiB with only a CPU request, and 2 GiB with no request at all. Silent,
#    while a container above its request beside them fires.
test("containers without a memory request",
     [ws("nomem", "nomem-0", "app", flat(G2)), req("nomem", "nomem-0", "app", flat(0.025), resource="cpu"),
      ws("noreq", "noreq-0", "app", flat(G2)),
      ws("app", "app-0", "app", flat(A)), req("app", "app-0", "app", flat(R))],
     [at(29 * 60, alert("app", "app-0", "app"))])

# 4. Restarted containers. dup-0 has two cgroups' series overlapping all day, 60 Mi each: merged
#    it is 60 Mi, summed it would be 120. restarted-0 restarts at 12h with a 10-minute overlap:
#    its history carries across, so it fires when a container that never restarted would.
test("restarted containers with overlapping series",
     [ws("dup", "dup-0", "app", flat(H), cid="c1"), ws("dup", "dup-0", "app", flat(H), cid="c2"),
      req("dup", "dup-0", "app", flat(R)),
      ws("restarted", "restarted-0", "app", run((A, 721), ("stale", 1)), cid="c1"),
      ws("restarted", "restarted-0", "app", run((None, 710), (A, T + 1 - 710)), cid="c2"),
      req("restarted", "restarted-0", "app", flat(R))],
     [at(22 * 60 + 55, alert("restarted", "restarted-0", "app")), at(29 * 60, alert("restarted", "restarted-0", "app"))])

# 5. A new pod, created at 6h and above its request all its life: not judged until it has 22 h
#    (27h55m), so it fires at 28h55m and not at 26h.
test("new pod",
     [ws("new", "new-0", "app", run((None, 360), (A, T + 1 - 360))), req("new", "new-0", "app", run((None, 360), (R, T + 1 - 360)))],
     [at(26 * 60), at(28 * 60 + 54), at(28 * 60 + 55, alert("new", "new-0", "app"))])

# 6. The 90% line: above for 95% of every 100 minutes fires; above for 80% does not.
c95 = enc([B if m % 100 < 5 else A for m in range(T + 1)])
c80 = enc([B if m % 100 < 20 else A for m in range(T + 1)])
test("above for 95% and for 80% of the day",
     [ws("c95", "c95-0", "app", c95), req("c95", "c95-0", "app", flat(R)),
      ws("c80", "c80-0", "app", c80), req("c80", "c80-0", "app", flat(R))],
     [at(29 * 60, alert("c95", "c95-0", "app"))])

# 7. The request raised. sts-0 keeps its name (a StatefulSet): 150 Mi from 24h resolves it at
#    once. app-old is replaced by app-new at 24h (a Deployment): the old pod's alert lingers while
#    its last request is within 15 minutes, and the new pod is under its new request.
test("request raised",
     [ws("sts", "sts-0", "app", flat(A)), req("sts", "sts-0", "app", run((R, 1440), (R2, T + 1 - 1440))),
      ws("roll", "app-old", "app", run((A, 1441), ("stale", 1))), req("roll", "app-old", "app", run((R, 1441), ("stale", 1))),
      ws("roll", "app-new", "app", run((None, 1440), (A, T + 1 - 1440))), req("roll", "app-new", "app", run((None, 1440), (R2, T + 1 - 1440)))],
     [at(23 * 60, alert("roll", "app-old", "app"), alert("sts", "sts-0", "app")),
      at(24 * 60, alert("roll", "app-old", "app")),
      at(24 * 60 + 10, alert("roll", "app-old", "app")),
      at(24 * 60 + 20)])

# 8. Gaps. kube-state-metrics misses 10 minutes at 24h: the alert stays firing. cAdvisor misses
#    30 minutes at 12h: the container is judged 30 minutes later, and still fires.
test("scrape gaps",
     [ws("ksm-gap", "ksm-gap-0", "app", flat(A)),
      req("ksm-gap", "ksm-gap-0", "app", run((R, 1441), ("stale", 1), (None, 9), (R, T + 1 - 1451))),
      ws("cadv-gap", "cadv-gap-0", "app", run((A, 721), ("stale", 1), (None, 29), (A, T + 1 - 751))),
      req("cadv-gap", "cadv-gap-0", "app", flat(R))],
     [at(23 * 60, alert("ksm-gap", "ksm-gap-0", "app")),
      at(23 * 60 + 24, alert("ksm-gap", "ksm-gap-0", "app")),
      at(23 * 60 + 30, alert("cadv-gap", "cadv-gap-0", "app"), alert("ksm-gap", "ksm-gap-0", "app")),
      at(24 * 60 + 5, alert("cadv-gap", "cadv-gap-0", "app"), alert("ksm-gap", "ksm-gap-0", "app")),
      at(29 * 60, alert("cadv-gap", "cadv-gap-0", "app"), alert("ksm-gap", "ksm-gap-0", "app"))])

# 9. Exactly at the request is not above it.
test("at the request", [ws("exact", "exact-0", "app", flat(R)), req("exact", "exact-0", "app", flat(R))],
     [at(29 * 60)])

# 10. Flux's and k3s's containers are left out; a monitoring container beside them is not.
test("excluded namespaces",
     [ws("flux-system", "kustomize-controller-0", "manager", flat(A)), req("flux-system", "kustomize-controller-0", "manager", flat(R)),
      ws("kube-system", "coredns-0", "coredns", flat(A)), req("kube-system", "coredns-0", "coredns", flat(R)),
      ws("monitoring", "grafana-0", "grafana", flat(A)), req("monitoring", "grafana-0", "grafana", flat(R))],
     [at(29 * 60, alert("monitoring", "grafana-0", "grafana"))])

# 11. True for only 30 minutes: judged at 21h55m, then its request is raised at 22h25m. The hour's
#     wait means it never fires.
test("true for 30 minutes",
     [ws("short", "short-0", "app", flat(A)), req("short", "short-0", "app", run((R, 1345), (R2, T + 1 - 1345)))],
     [at(22 * 60 + 10), at(23 * 60), at(29 * 60)])

doc = {"rule_files": ["../configs/production/prometheusrule-memory-requests.yaml"], "evaluation_interval": "1m",
       "tests": tests}
with open(os.path.join(sys.argv[1], "memory-requests.test.yaml"), "w") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False, width=100000)
