#!/usr/bin/env python3
"""Bound a node operation's blast radius by what a pull request changed.

This is one of two guards, and it is the cheaper, earlier one. It reads the
diff, so it catches a node operation the moment its text enters the repository,
before anything references it:

1. Cardinality: a pull request may introduce or alter at most one
   NodeOp/NodeOpUpgrade document. The operator reconciles each object
   independently — `concurrency` is a per-object field — so two objects merged
   together drain and reboot two nodes at once.
2. Bounded blast radius: every introduced or altered NodeOp/NodeOpUpgrade must
   either name one node by kubernetes.io/hostname, or be a NodeOpUpgrade that
   takes the cluster one node at a time — concurrency: 1 and stopOnFailure:
   true, the shape upstream documents for a cluster upgrade. An absent
   spec.nodeSelector targets every node at once (kairos-operator v0.2.2,
   internal/controller/nodeop_controller.go:1338); NodeOpUpgrade reaches the
   same code by constructing a NodeOp in nodeopupgrade_controller.go's
   createNodeOp, which copies the selector verbatim, so one rule covers both
   kinds. nodeop_common.check_bounded holds the detail.

What a diff cannot see is a document that was already in the repository and
becomes *reachable* — one pull request adds an unreferenced manifest, a later
one adds it to a `resources:` list. Nothing here changes, and a node reboots.
`nodeop_reachable.py` closes that by comparing what ArgoCD would render; it is
the load-bearing check, and this one is the net that catches the same class of
mistake a merge earlier. Neither subsumes the other's failure mode: a rendering
blind spot in one is not a diff blind spot in the other.

"Introduced or altered" is computed per changed file, by comparing the node
operations in the file's pre-image at the merge base against those in its
post-image. Both sides are canonicalised with yaml.safe_dump and sorted keys,
so the comparison is on parsed data: reordering a mapping, changing quoting
style, or editing a comment does not make a document count as altered, while
any change to a value does. That catches documents appended to an already
tracked file, ignores a document merely carried along by an edit elsewhere in
the same file, and follows renames.

Rename detection is on (`-M`); copy detection (`-C`) is deliberately off, so a
copied file is reported as an addition and its node operations count as
introduced — which is correct, since a copy is a second node operation. Under
`-C` the copy would be diffed against its source and count as zero. A `C`
status is therefore never expected, and is treated as an error rather than
silently handled.

Every changed path is parsed regardless of its name: Kustomize reads
`resources:` entries by content, not by extension. A path that is not YAML is
skipped in silence; a path that looks like YAML by name but does not parse is
a hard error.

Exit 0 on pass, 1 on a violation, 2 on a usage or parse error. Prints how many
documents it inspected, so a run that inspected nothing says so.
"""

import argparse
import collections
import subprocess
import sys

from nodeop_common import canonical, check_bounded, decode_manifest, describe, node_ops


def read_worktree(path):
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as err:
        print(f"ERROR: cannot read {path}: {err}")
        sys.exit(2)
    # None means binary. A byte-order-marked UTF-16 file is not binary: ArgoCD
    # decodes it and applies what is inside (nodeop_common.decode_manifest).
    return decode_manifest(raw)


def read_git(base, path):
    result = subprocess.run(
        ["git", "show", f"{base}:{path}"],
        capture_output=True,
    )
    if result.returncode != 0:
        return None        # absent at the merge base
    return decode_manifest(result.stdout)


def parse_changes(blob):
    """Parse `git diff --name-status -z` into (old_path, new_path) pairs."""
    fields = [f for f in blob.split("\0") if f != ""]
    changes = []
    index = 0
    while index < len(fields):
        status = fields[index]
        index += 1
        if status[:1] == "R":
            if index + 1 >= len(fields):
                print(f"ERROR: truncated rename record after {status}")
                sys.exit(2)
            changes.append((fields[index], fields[index + 1]))
            index += 2
        elif status[:1] in ("A", "M", "T"):
            if index >= len(fields):
                print(f"ERROR: truncated record after {status}")
                sys.exit(2)
            path = fields[index]
            changes.append((None if status[:1] == "A" else path, path))
            index += 1
        else:
            # C included: copy detection is off on purpose (see module docstring),
            # so a C status means the caller changed the diff flags.
            print(f"ERROR: unexpected diff status {status!r}")
            sys.exit(2)
    return changes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--changes", required=True,
                        help="file holding `git diff --name-status -z` output")
    parser.add_argument("--base", required=True,
                        help="revision to read each file's pre-image from")
    args = parser.parse_args()

    with open(args.changes, "rb") as handle:
        changes = parse_changes(handle.read().decode("utf-8"))

    introduced = []
    carried = 0
    for old_path, new_path in changes:
        post_text = read_worktree(new_path)
        if post_text is None:
            continue
        post = node_ops(post_text, new_path)
        if not post:
            continue
        pre = []
        if old_path is not None:
            pre_text = read_git(args.base, old_path)
            if pre_text is not None:
                pre = node_ops(pre_text, old_path)
        before = collections.Counter(canonical(d) for d in pre)
        for document in post:
            key = canonical(document)
            if before[key] > 0:
                before[key] -= 1
                carried += 1
            else:
                introduced.append((new_path, document))

    violations = []
    if len(introduced) > 1:
        listed = ", ".join(f"{p}:{describe(d)}" for p, d in introduced)
        violations.append(
            f"this pull request introduces or alters {len(introduced)} node "
            f"operations, maximum is 1: {listed}")
    for path, document in introduced:
        violations.extend(check_bounded(f"{path} ({describe(document)})", document))

    print(f"nodeop-guard: {len(changes)} changed path(s); "
          f"{len(introduced)} node operation(s) introduced or altered, "
          f"{carried} carried unchanged")
    if violations:
        for violation in violations:
            print(f"FAIL: {violation}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
