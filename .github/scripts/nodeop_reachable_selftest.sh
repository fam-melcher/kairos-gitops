#!/usr/bin/env bash
# Prove nodeop_reachable.py still detects, before trusting it on a pull request.
#
# The repository holds no NodeOp/NodeOpUpgrade manifests, so every run today
# finds zero reachable node operations and passes — indistinguishable from a
# guard that has stopped walking the closure at all. This script builds a pair
# of throwaway trees in a temp directory for each case, renders both with the
# real kustomize binary, asserts the exit code the guard must return, and fails
# CI if any is wrong.
#
# The fixtures are test inputs for a linter, not manifests: they exist only
# inside the mktemp directory the trap deletes, are under no path this
# repository tracks, and are reachable by no Application in any cluster.
set -euo pipefail

guard="$(cd "$(dirname "$0")" && pwd)/nodeop_reachable.py"
kustomize="${KUSTOMIZE:-kustomize}"
command -v "${kustomize}" >/dev/null \
  || { echo "SELFTEST FAIL: no kustomize binary — the guard cannot render"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
base="${work}/base"
head="${work}/head"
failures=0
cases=0
# Every case below must run. A case deleted or commented out would otherwise
# lower the bar in silence, which is the failure mode this script exists for.
expected_cases=37

SELF_REPO="https://github.com/fam-melcher/kairos-gitops"

node_op() {
  # $1 = name, $2 = hostname, $3 = image tag (default t1)
  cat <<YAML
apiVersion: operator.kairos.io/v1alpha1
kind: NodeOpUpgrade
metadata:
  name: $1
  namespace: kairos-system
spec:
  image: example.invalid/image:${3:-t1}
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: $2
YAML
}

seed() {
  # A minimal copy of this repository's real shape: a cluster root that
  # Kustomize-builds, one app overlay rendering an Application that points back
  # at the same repository, and the content directory that Application syncs.
  local tree="$1"
  rm -rf "${tree}"
  mkdir -p "${tree}/clusters/demo/apps/thing" "${tree}/clusters/demo/content" "${tree}/base/parked"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - apps/thing\n' \
    > "${tree}/clusters/demo/kustomization.yaml"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - application.yaml\n' \
    > "${tree}/clusters/demo/apps/thing/kustomization.yaml"
  cat > "${tree}/clusters/demo/apps/thing/application.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: content
  namespace: argocd
spec:
  project: default
  source:
    repoURL: ${SELF_REPO}
    targetRevision: HEAD
    path: clusters/demo/content
  destination:
    server: https://kubernetes.default.svc
    namespace: kairos-system
YAML
  printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: kairos-system\n' \
    > "${tree}/clusters/demo/content/namespace.yaml"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - namespace.yaml\n' \
    > "${tree}/clusters/demo/content/kustomization.yaml"
}

seed_pair() {
  seed "${base}"
  seed "${head}"
}

reference() {
  # $1 = tree, $2 = path relative to the content kustomization
  printf '  - %s\n' "$2" >> "$1/clusters/demo/content/kustomization.yaml"
}

run_case() {
  # run_case <want-rc> <label>
  local want="$1" label="$2" got=0
  cases=$((cases + 1))
  python3 "${guard}" --base "${base}" --head "${head}" --kustomize "${kustomize}" \
    > "${work}/out" 2>&1 || got=$?
  if [ "${got}" -ne "${want}" ]; then
    echo "SELFTEST FAIL: ${label}: expected exit ${want}, got ${got}"
    sed 's/^/    /' "${work}/out"
    failures=$((failures + 1))
  else
    echo "selftest ok: ${label}"
  fi
}

assert_out() {
  # assert_out <label> <grep pattern> — asserts the last run said what it meant
  cases=$((cases + 1))
  if grep -q "$2" "${work}/out"; then
    echo "selftest ok: $1"
  else
    echo "SELFTEST FAIL: $1: output does not match /$2/"
    sed 's/^/    /' "${work}/out"
    failures=$((failures + 1))
  fi
}

# 1. an unchanged tree with no node operations anywhere
seed_pair
run_case 0 "nothing reachable, nothing changed"

# 2. a node operation added but referenced by nothing. Harmless: ArgoCD renders
#    no such object. It is the *next* pull request, the one that references it,
#    that must be counted — see case 4.
seed_pair
node_op parked-a node-a > "${head}/base/parked/a.yaml"
run_case 0 "unreferenced manifest is not reachable"
assert_out "unreferenced manifest counts zero" "0 node operation(s) newly reachable"

# 3. one node operation added and referenced in the same pull request
seed_pair
node_op upgrade-a node-a > "${head}/clusters/demo/content/a.yaml"
reference "${head}" a.yaml
run_case 0 "one node operation added and referenced"

# 4. THE BYPASS nodeop_guard.py cannot see: both manifests were merged earlier,
#    each on its own and each passing the diff guard. This pull request changes
#    one kustomization.yaml and reboots two nodes.
seed_pair
for tree in "${base}" "${head}"; do
  node_op upgrade-a node-a > "${tree}/clusters/demo/content/a.yaml"
  node_op upgrade-b node-b > "${tree}/clusters/demo/content/b.yaml"
done
reference "${head}" a.yaml
reference "${head}" b.yaml
run_case 1 "two already-merged manifests referenced in one pull request"

# 5. the same bypass from outside clusters/. Kustomize's default load
#    restrictor blocks a *file* resource above the kustomization root, so the
#    parked manifests have to sit in a directory carrying its own
#    kustomization.yaml — which is exactly how every overlay in this repository
#    already reaches base/, and is one added line to reference.
park_pair() {
  local tree="$1"
  node_op upgrade-a node-a > "${tree}/base/parked/a.yaml"
  node_op upgrade-b node-b > "${tree}/base/parked/b.yaml"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - a.yaml\n  - b.yaml\n' \
    > "${tree}/base/parked/kustomization.yaml"
}

seed_pair
park_pair "${base}"
park_pair "${head}"
reference "${head}" ../../../base/parked
run_case 1 "a parked directory holding two manifests referenced at once"

# 6. the same reference, with one manifest in the parked directory
seed_pair
for tree in "${base}" "${head}"; do
  node_op upgrade-a node-a > "${tree}/base/parked/a.yaml"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - a.yaml\n' \
    > "${tree}/base/parked/kustomization.yaml"
done
reference "${head}" ../../../base/parked
run_case 0 "a parked directory holding one manifest referenced"

# 7. two node operations in one referenced file
seed_pair
{ node_op upgrade-a node-a; echo '---'; node_op upgrade-b node-b; } \
  > "${head}/clusters/demo/content/both.yaml"
reference "${head}" both.yaml
run_case 1 "two documents in one referenced file"

# 8. a node operation reachable on both sides, untouched
seed_pair
for tree in "${base}" "${head}"; do
  node_op upgrade-a node-a > "${tree}/clusters/demo/content/a.yaml"
  reference "${tree}" a.yaml
done
run_case 0 "already reachable and unchanged"
assert_out "an unchanged reachable operation is carried, not counted" "1 unchanged"

# 9. an already reachable node operation whose image is bumped in place —
#    a new upgrade of the same node, so it counts as one
seed_pair
for tree in "${base}" "${head}"; do reference "${tree}" a.yaml; done
node_op upgrade-a node-a t1 > "${base}/clusters/demo/content/a.yaml"
node_op upgrade-a node-a t2 > "${head}/clusters/demo/content/a.yaml"
run_case 0 "one reachable node operation altered in place"

# 10. two of them altered in place
seed_pair
for tree in "${base}" "${head}"; do reference "${tree}" a.yaml; reference "${tree}" b.yaml; done
node_op upgrade-a node-a t1 > "${base}/clusters/demo/content/a.yaml"
node_op upgrade-b node-b t1 > "${base}/clusters/demo/content/b.yaml"
node_op upgrade-a node-a t2 > "${head}/clusters/demo/content/a.yaml"
node_op upgrade-b node-b t2 > "${head}/clusters/demo/content/b.yaml"
run_case 1 "two reachable node operations altered in place"

# 11. a reachable node operation with no selector targets every node
seed_pair
printf 'apiVersion: operator.kairos.io/v1alpha1\nkind: NodeOp\nmetadata:\n  name: n\n  namespace: kairos-system\nspec:\n  command: ["true"]\n' \
  > "${head}/clusters/demo/content/a.yaml"
reference "${head}" a.yaml
run_case 1 "reachable node operation with no nodeSelector"

# 12. matchExpressions: [] alongside a valid hostname label — rejected on the
#     key's presence, matching nodeop_guard.py and ADR 0013
seed_pair
printf 'apiVersion: operator.kairos.io/v1alpha1\nkind: NodeOp\nmetadata:\n  name: x\n  namespace: kairos-system\nspec:\n  command: ["true"]\n  nodeSelector:\n    matchExpressions: []\n    matchLabels:\n      kubernetes.io/hostname: node-a\n' \
  > "${head}/clusters/demo/content/a.yaml"
reference "${head}" a.yaml
run_case 1 "reachable node operation with an empty matchExpressions list"

# 13. a directory-type source — no kustomization.yaml, so ArgoCD applies the
#     YAML in that directory as it stands
seed_pair
for tree in "${base}" "${head}"; do rm "${tree}/clusters/demo/content/kustomization.yaml"; done
node_op upgrade-a node-a > "${head}/clusters/demo/content/a.yaml"
node_op upgrade-b node-b > "${head}/clusters/demo/content/b.yaml"
run_case 1 "two node operations in a directory-type source"

# 14. the same source, non-recursive (the default): ArgoCD does not descend, so
#     a manifest in a subdirectory is not applied and must not be counted
seed_pair
for tree in "${base}" "${head}"; do rm "${tree}/clusters/demo/content/kustomization.yaml"; done
mkdir -p "${head}/clusters/demo/content/nested"
node_op upgrade-a node-a > "${head}/clusters/demo/content/a.yaml"
node_op upgrade-b node-b > "${head}/clusters/demo/content/nested/b.yaml"
node_op upgrade-c node-c > "${head}/clusters/demo/content/nested/c.yaml"
run_case 0 "a non-recursive directory source ignores subdirectories"

# 15. the same tree with directory.recurse: true — now the subdirectory counts
seed_pair
for tree in "${base}" "${head}"; do
  rm "${tree}/clusters/demo/content/kustomization.yaml"
  sed 's|    path: clusters/demo/content|    path: clusters/demo/content\n    directory:\n      recurse: true|' \
    "${tree}/clusters/demo/apps/thing/application.yaml" > "${work}/patched"
  mv "${work}/patched" "${tree}/clusters/demo/apps/thing/application.yaml"
done
mkdir -p "${head}/clusters/demo/content/nested"
node_op upgrade-b node-b > "${head}/clusters/demo/content/nested/b.yaml"
node_op upgrade-c node-c > "${head}/clusters/demo/content/nested/c.yaml"
run_case 1 "directory.recurse: true descends"

# 16. an extensionless file: Kustomize reads it by content, ArgoCD's directory
#     reader does not. Referenced through a kustomization it must count.
seed_pair
{ node_op upgrade-a node-a; echo '---'; node_op upgrade-b node-b; } \
  > "${head}/clusters/demo/content/reboot-pair"
reference "${head}" reboot-pair
run_case 1 "an extensionless file referenced by a kustomization"

# 17. a self-referencing Application pinned to something other than the default
#     branch: the tree rendered here is not the tree it would apply
seed_pair
sed 's/targetRevision: HEAD/targetRevision: v1.2.3/' \
  "${head}/clusters/demo/apps/thing/application.yaml" > "${work}/patched"
mv "${work}/patched" "${head}/clusters/demo/apps/thing/application.yaml"
run_case 2 "a self-reference pinned to a tag is an error"

# 18. an ApplicationSet generates Applications this guard does not expand
seed_pair
cat >> "${head}/clusters/demo/apps/thing/kustomization.yaml" <<YAML
  - appset.yaml
YAML
cat > "${head}/clusters/demo/apps/thing/appset.yaml" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: generated
  namespace: argocd
spec:
  generators: []
  template: {}
YAML
run_case 2 "an ApplicationSet is an error, not a pass"

# 19. an Application pointing at a path that does not exist
seed_pair
rm -rf "${head}/clusters/demo/content"
run_case 2 "a missing referenced path is an error"

# 20. a render that fails
seed_pair
printf '  - does-not-exist.yaml\n' >> "${head}/clusters/demo/content/kustomization.yaml"
run_case 2 "a failing kustomize build is an error"

# 21. a malformed manifest in a directory-type source. ArgoCD fails on it, so a
#     guard that shrugged and carried on would be counting a set nobody applies.
seed_pair
for tree in "${base}" "${head}"; do rm "${tree}/clusters/demo/content/kustomization.yaml"; done
printf 'a:\n  - b\n c: [\n' > "${head}/clusters/demo/content/broken.yaml"
run_case 2 "a malformed manifest in a directory source is an error"

# 22. the other half of the load restrictor: a resources: entry naming a *file*
#     above the kustomization root. kustomize refuses it, which is why the
#     parking shape in cases 5 and 6 has to be a directory. If a kustomize
#     upgrade ever relaxes this, this case flips and the ADR's reasoning about
#     what can be parked has to be rewritten.
seed_pair
node_op upgrade-a node-a > "${head}/base/parked/a.yaml"
reference "${head}" ../../../base/parked/a.yaml
run_case 2 "a file resource above the kustomization root is refused"
assert_out "the refusal comes from the render, not from a parse" "kustomize build"

# 23. a self-referencing Application that renders with Helm: this script reads
#     the directory, not the templates, so the node operation inside a chart
#     would be invisible
seed_pair
sed 's|    path: clusters/demo/content|    path: clusters/demo/content\n    helm:\n      releaseName: demo|' \
  "${head}/clusters/demo/apps/thing/application.yaml" > "${work}/patched"
mv "${work}/patched" "${head}/clusters/demo/apps/thing/application.yaml"
run_case 2 "a self-referencing Helm source is an error"

# 24. kustomize patches applied by ArgoCD after the build can rewrite the
#     nodeSelector this script has already checked
seed_pair
sed 's|    path: clusters/demo/content|    path: clusters/demo/content\n    kustomize:\n      patches:\n        - target:\n            kind: NodeOpUpgrade\n          patch: "[]"|' \
  "${head}/clusters/demo/apps/thing/application.yaml" > "${work}/patched"
mv "${work}/patched" "${head}/clusters/demo/apps/thing/application.yaml"
run_case 2 "post-build kustomize patches are an error"

# 25. a config management plugin renders something this script cannot predict
seed_pair
sed 's|    path: clusters/demo/content|    path: clusters/demo/content\n    plugin:\n      name: demo-plugin|' \
  "${head}/clusters/demo/apps/thing/application.yaml" > "${work}/patched"
mv "${work}/patched" "${head}/clusters/demo/apps/thing/application.yaml"
run_case 2 "a config management plugin source is an error"

# 26. --list-roots is what the render job builds. If it ever prints fewer roots
#     than the closure walks, render stops covering what ArgoCD renders.
seed_pair
roots="$(python3 "${guard}" --list-roots "${head}" --kustomize "${kustomize}" 2>/dev/null)"
cases=$((cases + 1))
if [ "${roots}" = "kustomize clusters/demo
kustomize clusters/demo/content" ]; then
  echo "selftest ok: --list-roots prints seed and child roots"
else
  echo "SELFTEST FAIL: --list-roots printed:"
  printf '%s\n' "${roots}" | sed 's/^/    /'
  failures=$((failures + 1))
fi

# 27. a directory-type root is tagged as one, so the render job can skip it
#     rather than fail trying to kustomize build it
seed_pair
rm "${head}/clusters/demo/content/kustomization.yaml"
roots="$(python3 "${guard}" --list-roots "${head}" --kustomize "${kustomize}" 2>/dev/null)"
cases=$((cases + 1))
if printf '%s\n' "${roots}" | grep -q '^directory clusters/demo/content$'; then
  echo "selftest ok: --list-roots tags a directory-type root"
else
  echo "SELFTEST FAIL: --list-roots did not tag the directory root:"
  printf '%s\n' "${roots}" | sed 's/^/    /'
  failures=$((failures + 1))
fi

# 28. three node operations wrapped in a kind: List, in a directory-type source.
#     ArgoCD unwraps a List for every source type before anything else sees it.
seed_pair
for tree in "${base}" "${head}"; do rm "${tree}/clusters/demo/content/kustomization.yaml"; done
python3 - "${head}/clusters/demo/content/fleet.yaml" <<'PYEOF'
import sys
item = """  - apiVersion: operator.kairos.io/v1alpha1
    kind: NodeOpUpgrade
    metadata:
      name: %s
      namespace: kairos-system
    spec:
      image: example.invalid/image:t1
      nodeSelector:
        matchLabels:
          kubernetes.io/hostname: %s
"""
with open(sys.argv[1], "w") as handle:
    handle.write("apiVersion: v1\nkind: List\nitems:\n")
    for name, host in (("a", "node-a"), ("b", "node-b"), ("c", "node-c")):
        handle.write(item % (name, host))
PYEOF
run_case 1 "three node operations inside a kind: List"

# 29. a UTF-16 manifest in a directory-type source: ArgoCD decodes the
#     byte-order mark, so this guard has to as well
seed_pair
for tree in "${base}" "${head}"; do rm "${tree}/clusters/demo/content/kustomization.yaml"; done
python3 - "${head}/clusters/demo/content/utf16.yaml" <<'PYEOF'
import sys
doc = """apiVersion: operator.kairos.io/v1alpha1
kind: NodeOpUpgrade
metadata:
  name: %s
  namespace: kairos-system
spec:
  image: example.invalid/image:t1
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: %s
"""
text = doc % ("a", "node-a") + "---\n" + doc % ("b", "node-b")
open(sys.argv[1], "wb").write(text.encode("utf-16"))
PYEOF
run_case 1 "two node operations in a UTF-16 manifest"

# 30. a file that is not text in any encoding ArgoCD reads, but is named as a
#     manifest: an error, not a silent skip
seed_pair
for tree in "${base}" "${head}"; do rm "${tree}/clusters/demo/content/kustomization.yaml"; done
printf '\x00\x01\x02\xff\xfe kind: NodeOp\n' > "${head}/clusters/demo/content/blob.yaml"
run_case 2 "an undecodable file named as a manifest is an error"

# 31. jsonnet: ArgoCD evaluates it, this script cannot
seed_pair
for tree in "${base}" "${head}"; do rm "${tree}/clusters/demo/content/kustomization.yaml"; done
printf '[{apiVersion: "operator.kairos.io/v1alpha1", kind: "NodeOp"}]\n' \
  > "${head}/clusters/demo/content/fleet.jsonnet"
run_case 2 "a jsonnet manifest is an error"

# 32. a Chart.yaml turns the path into a Helm source without any spec.source.helm
#     block — ArgoCD classifies by what is in the directory
seed_pair
for tree in "${base}" "${head}"; do rm "${tree}/clusters/demo/content/kustomization.yaml"; done
mkdir -p "${head}/clusters/demo/content/templates"
printf 'apiVersion: v2\nname: demo\nversion: 0.1.0\n' > "${head}/clusters/demo/content/Chart.yaml"
node_op upgrade-a node-a > "${head}/clusters/demo/content/templates/all.yaml"
run_case 2 "a Chart.yaml in a directory source is an error"

# 33. sourceHydrator renders from a branch that is not this tree
seed_pair
cat >> "${head}/clusters/demo/apps/thing/application.yaml" <<YAML
  sourceHydrator:
    drySource:
      repoURL: ${SELF_REPO}
      targetRevision: HEAD
      path: clusters/demo/content
YAML
run_case 2 "a sourceHydrator Application is an error"

# 34. the same self-referential List, reached through a directory source
seed_pair
for tree in "${base}" "${head}"; do rm "${tree}/clusters/demo/content/kustomization.yaml"; done
printf '&a\nkind: SomeList\nitems:\n  - *a\n' > "${head}/clusters/demo/content/loop.yaml"
run_case 2 "a self-referential kind: List is an error, not a hang"

if [ "${cases}" -ne "${expected_cases}" ]; then
  echo "nodeop-reachable self-test: ran ${cases} cases, expected ${expected_cases}"
  exit 1
fi
if [ "${failures}" -ne 0 ]; then
  echo "nodeop-reachable self-test: ${failures} case(s) wrong — the guard is not trustworthy"
  exit 1
fi
echo "nodeop-reachable self-test: all ${cases} cases correct"
