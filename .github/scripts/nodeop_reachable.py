#!/usr/bin/env python3
"""Bound node operations by what ArgoCD would apply, not by what a diff touched.

`nodeop_guard.py` reads the pull request's diff, which misses the two-merge
bypass: one pull request adds `base/reboot-a.yaml` (one node operation, it
passes), a second adds `base/reboot-b.yaml` (also one, it passes), and a third
adds both to a `resources:` list. The third changes a single kustomization.yaml,
introduces no document, satisfies the diff guard — and reboots two nodes at
once. Nothing in the repository was unsafe until the line that referenced it.

So this check compares sets of *reachable* node operations, at the merge base
and at the pull request head, and enforces the same two invariants on what is
newly reachable:

1. Cardinality: at most one node operation becomes reachable per pull request.
2. Bounded blast radius: each newly reachable node operation either names one
   node by kubernetes.io/hostname, or is a NodeOpUpgrade taking the cluster one
   node at a time with concurrency: 1 and stopOnFailure: true (rules and
   evidence in nodeop_common.check_bounded).

Reachability is ArgoCD's own closure, walked the way ArgoCD walks it. The seeds
are `clusters/*/` — the paths kairos-configs points each cluster's root
Application at (README; kairos-configs ADR 0015). Each root is rendered the way
ArgoCD renders it: `kustomize build` where a kustomization.yaml exists,
otherwise a plain directory read of .yaml/.yml/.json. Every rendered Application
whose source points back at this repository contributes its own
`spec.source.path` as a further root, recursively — so an `upgrades/` directory
synced by a child Application is inside the closure, while an unreferenced file
parked under `base/` is outside it and counts for nothing until something
references it.

Fail closed. Anything the closure cannot model is an error, not a pass: an
ApplicationSet (it generates Applications this script does not expand); a
self-referencing Application pinned to a revision other than the default branch
(the tree rendered here would not be the tree applied), or one rendering through
Helm, a config management plugin or a sourceHydrator, or carrying kustomize
patches or components that rewrite manifests after this script read them; a
directory holding a Chart.yaml, which makes ArgoCD render it as a chart and skip
templates/ here; a .jsonnet file, which ArgoCD evaluates and this cannot; a file
named as a manifest that is not text in an encoding ArgoCD reads; a referenced
path that does not exist; and a render or a parse that fails.

An Application sourcing a different repository is out of scope rather than
fenced: its content is not in this git history, so nothing here can see what it
applies. Each such repository is named once on stderr.

Exit 0 on pass, 1 on a violation, 2 on a usage, render, or parse error.
"""

import argparse
import collections
import os
import subprocess
import sys

from nodeop_common import (canonical, check_bounded, decode_manifest, describe,
                           is_node_op, parse_strict)

# This repository, in every spelling an Application might use. Compared after
# normalise_repo() strips scheme, credentials, a .git suffix and a trailing
# slash, so only the host and path need to be listed.
SELF_REPOS = ("github.com/fam-melcher/kairos-gitops",)

# The root Application kairos-configs bootstraps uses HEAD, and every
# self-referencing Application in this repo matches it (ADR 0007). Both spell
# the default branch, whose content after this pull request merges is the head
# tree rendered here. Any other revision renders something else, and this script
# says so rather than guessing.
SELF_REVISIONS = ("", "head", "main")

APP_GROUP = "argoproj.io/"
KUSTOMIZATION_NAMES = ("kustomization.yaml", "kustomization.yml", "Kustomization")
# What ArgoCD's directory reader picks up:
# `^.*\.(yaml|yml|json|jsonnet)$` (reposerver/repository/repository.go).
DIRECTORY_SUFFIXES = (".yaml", ".yml", ".json", ".jsonnet")
# A directory holding one of these is not a directory-type source at all:
# util/app/discovery/discovery.go classifies the path by what is in it, so a
# Chart.yaml turns the source into a Helm release whose templates this script
# never reads. No `spec.source.helm` block is needed for that to happen.
HELM_NAMES = ("Chart.yaml", "Chart.yml")


def fail(message):
    # stderr: --list-roots' stdout is read by the render job, which would
    # otherwise swallow this message into its roots list.
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(2)


def normalise_repo(url):
    text = str(url).strip().lower()
    for scheme in ("https://", "http://", "ssh://", "git+ssh://", "git://"):
        if text.startswith(scheme):
            text = text[len(scheme):]
            break
    if text.startswith("git@"):
        text = text[len("git@"):].replace(":", "/", 1)
    host, _, rest = text.partition("/")
    if "@" in host:                       # user:password@host
        host = host.split("@", 1)[1]
    text = f"{host}/{rest}" if rest else host
    text = text.rstrip("/")
    if text.endswith(".git"):
        text = text[: -len(".git")]
    return text


def is_self(url):
    return normalise_repo(url) in SELF_REPOS


def resolve(tree, relative, label):
    """Absolute path of `relative` inside `tree`, or exit 2 if it escapes."""
    root = os.path.realpath(tree)
    target = os.path.realpath(os.path.join(root, relative))
    if target != root and not target.startswith(root + os.sep):
        fail(f"{label}: path {relative!r} resolves outside the repository")
    return target


def kustomization_in(directory):
    for name in KUSTOMIZATION_NAMES:
        candidate = os.path.join(directory, name)
        if os.path.isfile(candidate):
            return candidate
    return None


def read_text(path, label):
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as err:
        fail(f"cannot read {path}: {err}")
    text = decode_manifest(raw)
    if text is None:
        # ArgoCD would have read this file — it is named as a manifest and sits
        # in a directory ArgoCD applies. Skipping it silently is how three node
        # operations in a UTF-16 file become zero.
        fail(f"{label}: {path} is named as a manifest but is not text in any "
             f"encoding ArgoCD reads (UTF-8, or UTF-16/32 with a byte-order mark)")
    return text


def render_directory(directory, relative, recurse, label):
    """What ArgoCD applies for a directory-type source.

    Its reader takes .yaml/.yml/.json/.jsonnet and nothing else, so a manifest
    in a file named anything else is not applied and is not counted — while
    .jsonnet is applied and cannot be read here, which is an error.
    """
    documents = []
    if recurse:
        walked = []
        for current, _, names in os.walk(directory):
            walked.extend(os.path.join(current, name) for name in names)
        files = sorted(walked)
    else:
        files = sorted(
            os.path.join(directory, name) for name in os.listdir(directory)
            if os.path.isfile(os.path.join(directory, name))
        )
    for path in files:
        if not path.lower().endswith(DIRECTORY_SUFFIXES):
            continue
        shown = os.path.join(relative, os.path.relpath(path, directory))
        if path.lower().endswith(".jsonnet"):
            fail(f"{label}: {shown} is jsonnet, which ArgoCD evaluates and this "
                 f"script cannot. Whatever it generates would be invisible here.")
        text = read_text(path, label)
        documents.extend((shown, d) for d in parse_strict(text, shown) if isinstance(d, dict))
    if not documents:
        print(f"  {label}: {relative} (directory, recurse={recurse}) rendered nothing",
              file=sys.stderr)
    return documents


def render_kustomize(directory, relative, kustomize, label):
    result = subprocess.run(
        [kustomize, "build", directory],
        capture_output=True,
    )
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", "replace").strip()
        fail(f"{label}: kustomize build {relative} failed:\n{stderr}")
    text = result.stdout.decode("utf-8", "replace")
    return [(relative, d) for d in parse_strict(text, f"kustomize build {relative}")
            if isinstance(d, dict)]


def render(tree, relative, recurse, kustomize, label):
    directory = resolve(tree, relative, label)
    if not os.path.isdir(directory):
        fail(f"{label}: {relative} is referenced by an Application but is not a directory")
    for name in HELM_NAMES:
        if os.path.isfile(os.path.join(directory, name)):
            fail(f"{label}: {relative} holds {name}, so ArgoCD renders it as a "
                 f"Helm chart and this script would read the directory instead "
                 f"of the templates")
    if kustomization_in(directory):
        return render_kustomize(directory, relative, kustomize, label)
    return render_directory(directory, relative, recurse, label)


def spec_of(document):
    spec = document.get("spec")
    return spec if isinstance(spec, dict) else {}


def sources_of(document):
    spec = document.get("spec")
    if not isinstance(spec, dict):
        return []
    found = []
    single = spec.get("source")
    if isinstance(single, dict):
        found.append(single)
    multiple = spec.get("sources")
    if isinstance(multiple, list):
        found.extend(source for source in multiple if isinstance(source, dict))
    return found


def seeds_of(tree, label):
    """clusters/<name>/ — what each cluster's root Application syncs."""
    clusters = resolve(tree, "clusters", label)
    if not os.path.isdir(clusters):
        fail(f"{label}: no clusters/ directory — the repository layout this guard "
             f"models (README, ADR 0005) is gone, so its closure cannot be trusted")
    names = sorted(name for name in os.listdir(clusters)
                   if os.path.isdir(os.path.join(clusters, name)))
    if not names:
        fail(f"{label}: clusters/ holds no cluster directories")
    # recurse=True for a seed without a kustomization.yaml: root's own
    # directory.recurse lives in kairos-configs, outside this repository, so the
    # guard assumes the wider of the two readings rather than the safer-looking
    # one. Every cluster carries a kustomization.yaml today (ADR 0005), which
    # makes this a fallback, not the normal path.
    return [(f"clusters/{name}", True) for name in names]


def reachable(tree, kustomize, label):
    """Every node operation ArgoCD would apply from this tree.

    Returns (operations, roots): the node operations found, and every path the
    closure rendered, tagged with how it was rendered. `--list-roots` prints the
    second so the render job can build exactly what ArgoCD builds rather than a
    hand-kept subset of it.
    """
    queue = collections.deque(seeds_of(tree, label))
    seen = set()
    foreign = set()
    operations = []
    roots = []
    while queue:
        relative, recurse = queue.popleft()
        if (relative, recurse) in seen:
            continue
        seen.add((relative, recurse))
        kind_of_root = "kustomize" if kustomization_in(resolve(tree, relative, label)) else "directory"
        roots.append((kind_of_root, relative))
        for where, document in render(tree, relative, recurse, kustomize, label):
            kind = document.get("kind")
            api = str(document.get("apiVersion", ""))
            if is_node_op(document):
                operations.append((relative, f"{label}:{where}", document))
                continue
            if not api.startswith(APP_GROUP):
                continue
            if kind == "ApplicationSet":
                fail(f"{label}: {where} renders an ApplicationSet. It generates "
                     f"Applications this guard does not expand, so the reachable "
                     f"set would be incomplete. Teach this script to expand it "
                     f"before merging one.")
            if kind != "Application":
                continue
            if isinstance(spec_of(document).get("sourceHydrator"), dict):
                fail(f"{label}: {where} ({describe(document)}) uses a "
                     f"sourceHydrator, whose rendered branch is not this tree")
            for source in sources_of(document):
                url = source.get("repoURL")
                if url is None:
                    continue
                if not is_self(url):
                    # Out of scope, but said out loud once per repository: the
                    # content is not in this git history, so neither guard can
                    # see what it applies (ADR 0013).
                    if url not in foreign:
                        foreign.add(url)
                        print(f"  {label}: {url} is sourced from outside this "
                              f"repository and is not walked", file=sys.stderr)
                    continue
                # A source that only names value files for a sibling source
                # renders nothing of its own.
                if source.get("ref") and "path" not in source:
                    continue
                # Everything below rewrites or generates manifests after the
                # point this script reads them, so what it validated would not
                # be what ArgoCD applies. Fail closed, the way an ApplicationSet
                # does, rather than report on a tree nobody syncs.
                for key, why in (
                    ("chart", "sources a Helm chart; the closure models git paths only"),
                    ("helm", "renders with Helm; this script reads the directory, "
                             "not the templates"),
                    ("plugin", "renders with a config management plugin, whose "
                               "output this script cannot predict"),
                ):
                    if source.get(key):
                        fail(f"{label}: {where} ({describe(document)}) {why}")
                kustomize_options = source.get("kustomize")
                if isinstance(kustomize_options, dict):
                    rewrites = sorted(
                        key for key in kustomize_options
                        if key.startswith("patches") or key == "components"
                    )
                    if rewrites:
                        fail(f"{label}: {where} ({describe(document)}) applies "
                             f"{', '.join(rewrites)} after the build, which can "
                             f"rewrite a nodeSelector this script has already "
                             f"checked")
                revision = str(source.get("targetRevision", "")).strip().lower()
                if revision not in SELF_REVISIONS:
                    fail(f"{label}: {where} ({describe(document)}) points at this "
                         f"repository at revision {source.get('targetRevision')!r}. "
                         f"This guard renders the pull request's tree, which is "
                         f"not what that Application would apply.")
                path = str(source.get("path", ".")).strip() or "."
                directory = source.get("directory")
                child_recurse = bool(isinstance(directory, dict)
                                     and directory.get("recurse"))
                queue.append((os.path.normpath(path), child_recurse))
    # stderr: --list-roots' stdout is a machine-read list of roots.
    print(f"{label}: {len(roots)} root(s) rendered, "
          f"{len(operations)} node operation(s) reachable", file=sys.stderr)
    return operations, roots


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", help="a checkout of the merge base")
    parser.add_argument("--head", help="a checkout of the pull request head")
    parser.add_argument("--list-roots", metavar="TREE",
                        help="walk one tree and print every root the closure "
                             "renders, as `<kustomize|directory> <path>`, "
                             "instead of comparing two trees")
    parser.add_argument("--kustomize", default="kustomize",
                        help="kustomize binary to render with")
    args = parser.parse_args()

    if args.list_roots:
        if args.base or args.head:
            parser.error("--list-roots walks one tree; drop --base and --head")
        _, roots = reachable(args.list_roots, args.kustomize, "tree")
        for kind_of_root, relative in roots:
            print(f"{kind_of_root} {relative}")
        return 0
    if not (args.base and args.head):
        parser.error("--base and --head are both required")

    base, _ = reachable(args.base, args.kustomize, "base")
    head, _ = reachable(args.head, args.kustomize, "head")

    # Keyed by root as well as content: the same document reachable from a
    # different root is a different object applied to a different cluster, and
    # "unchanged" has to mean unchanged in place.
    before = collections.Counter((root, canonical(document)) for root, _, document in base)
    newly = []
    carried = 0
    for root, where, document in head:
        key = (root, canonical(document))
        if before[key] > 0:
            before[key] -= 1
            carried += 1
        else:
            newly.append((where, document))

    violations = []
    if len(newly) > 1:
        listed = ", ".join(f"{where}:{describe(document)}" for where, document in newly)
        violations.append(
            f"this pull request makes {len(newly)} node operations reachable, "
            f"maximum is 1: {listed}")
    for where, document in newly:
        violations.extend(check_bounded(f"{where} ({describe(document)})", document))

    print(f"nodeop-reachable: {len(newly)} node operation(s) newly reachable, "
          f"{carried} unchanged")
    if violations:
        for violation in violations:
            print(f"FAIL: {violation}")
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
