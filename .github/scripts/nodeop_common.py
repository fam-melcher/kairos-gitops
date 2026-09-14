"""Parsing and selector rules shared by the two node-operation guards.

`nodeop_guard.py` compares a pull request's changed files against their
pre-images at the merge base. `nodeop_reachable.py` compares the manifests
ArgoCD would actually render before and after the same pull request. The two
answer different questions, but they must agree on what a node operation is and
on which selectors are allowed — so those rules live here rather than in two
copies free to drift apart.
"""

import codecs
import sys

import yaml

GROUP = "operator.kairos.io/"
KINDS = ("NodeOp", "NodeOpUpgrade")
HOSTNAME = "kubernetes.io/hostname"
YAML_SUFFIXES = (".yaml", ".yml")


def looks_like_yaml(path):
    return path.lower().endswith(YAML_SUFFIXES)


# ArgoCD reads a manifest with utfutil.OpenFile(..., utfutil.UTF8)
# (reposerver/repository/repository.go), which decodes a byte-order mark instead
# of failing on it. A guard that treats a UTF-16 file as binary and skips it
# reads nothing where ArgoCD reads three node operations.
BOMS = (
    (codecs.BOM_UTF8, "utf-8-sig"),
    (codecs.BOM_UTF32_LE, "utf-32"),
    (codecs.BOM_UTF32_BE, "utf-32"),
    (codecs.BOM_UTF16_LE, "utf-16"),
    (codecs.BOM_UTF16_BE, "utf-16"),
)


def decode_manifest(raw):
    """Decode file bytes the way ArgoCD does, or None if they are not text."""
    for bom, encoding in BOMS:
        if raw.startswith(bom):
            try:
                return raw.decode(encoding)
            except (UnicodeDecodeError, LookupError):
                return None
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def flatten(documents):
    """Expand `kind: List` wrappers, as ArgoCD does to every source's output.

    `obj.IsList()` / `obj.EachListItem()` in reposerver/repository/repository.go
    unwraps a List before anything else sees it, for every source type. Without
    the same step here, three NodeOpUpgrades inside one `kind: List` are one
    document with a kind this guard does not recognise.
    """
    expanded = []
    pending = list(documents)
    # A YAML anchor can make a List hold itself, which would expand forever.
    # The dict is kept, not just its id(), so the id cannot be reused by a
    # later object once this one is collected.
    seen = {}
    while pending:
        document = pending.pop(0)
        if not isinstance(document, dict):
            continue
        items = document.get("items")
        if isinstance(items, list) and str(document.get("kind", "")).endswith("List"):
            if id(document) in seen:
                print("ERROR: a kind: List contains itself, through a YAML "
                      "anchor or alias; refusing to expand it")
                sys.exit(2)
            seen[id(document)] = document
            pending = items + pending
            continue
        expanded.append(document)
    return expanded


def is_node_op(document):
    return (
        isinstance(document, dict)
        and str(document.get("apiVersion", "")).startswith(GROUP)
        and document.get("kind") in KINDS
    )


def parse_documents(text, path):
    """Parse one YAML stream, or exit 2 if a file named as YAML does not parse.

    A path that is not named as YAML and does not parse is not YAML at all — a
    .py, a .md, a log file — and is skipped in silence.
    """
    try:
        return flatten(yaml.safe_load_all(text))
    except yaml.YAMLError as err:
        if looks_like_yaml(path):
            print(f"ERROR: {path} is named as YAML but does not parse: {err}")
            sys.exit(2)
        return []
    except RecursionError:
        print(f"ERROR: {path} could not be parsed safely")
        sys.exit(2)


def parse_strict(text, label):
    """Parse one YAML stream that must parse — anything else is exit 2.

    parse_documents() forgives a file that is not YAML at all, because it is
    handed every path a diff touched. Its caller here has already decided the
    text is a manifest: rendered kustomize output, or a file ArgoCD would apply
    from a directory-type source by its .yaml/.yml/.json name. If that does not
    parse, ArgoCD fails too, and guessing past it would silently drop documents
    from the set this guard exists to count.
    """
    try:
        return flatten(yaml.safe_load_all(text))
    except yaml.YAMLError as err:
        print(f"ERROR: {label} does not parse as YAML: {err}")
        sys.exit(2)
    except RecursionError:
        print(f"ERROR: {label} could not be parsed safely")
        sys.exit(2)


def node_ops(text, path):
    """Return the NodeOp/NodeOpUpgrade documents in one YAML stream."""
    return [d for d in parse_documents(text, path) if is_node_op(d)]


def canonical(document):
    return yaml.safe_dump(document, sort_keys=True, default_flow_style=False)


def describe(document):
    metadata = document.get("metadata")
    name = metadata.get("name", "<unnamed>") if isinstance(metadata, dict) else "<unnamed>"
    return f"{document.get('kind')}/{name}"


def check_selector(where, document):
    """Return a list of violation strings for one node operation.

    The rule is "cannot reach more than one node", not "looks like one label".
    `matchLabels` is an AND, so `kubernetes.io/hostname` present and naming a
    node is already the bound: any further label can only narrow, and the
    upgrade runbook's manifests carry `kairos.io/managed: "true"` alongside the
    hostname on purpose. `matchExpressions` is the one that can widen — an `In`
    list over three nodes reads like a selector and upgrades a cluster — and is
    rejected on the key's presence, not on its truthiness: `matchExpressions: []`
    is harmless, but a guard that accepts a key its ADR calls rejected cannot be
    read from its documentation, and the next edit to an accepted key is not
    empty.
    """
    spec = document.get("spec")
    if not isinstance(spec, dict):
        return [f"{where}: no spec"]
    selector = spec.get("nodeSelector")
    if selector is None:
        return [f"{where}: no spec.nodeSelector — this targets every node"]
    if not isinstance(selector, dict):
        return [f"{where}: spec.nodeSelector is not a label selector"]
    if "matchExpressions" in selector:
        return [f"{where}: spec.nodeSelector.matchExpressions is not allowed"]
    labels = selector.get("matchLabels")
    if not isinstance(labels, dict) or HOSTNAME not in labels:
        return [f"{where}: spec.nodeSelector.matchLabels must name {HOSTNAME}, "
                f"got {sorted(labels) if isinstance(labels, dict) else labels!r}"]
    value = labels[HOSTNAME]
    if not isinstance(value, str) or not value.strip():
        return [f"{where}: {HOSTNAME} must be a non-empty string"]
    return []
