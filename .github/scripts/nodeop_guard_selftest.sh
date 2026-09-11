#!/usr/bin/env bash
# Prove nodeop_guard.py still detects, before trusting it on a pull request.
#
# The repo holds no NodeOp/NodeOpUpgrade manifests, so on every run today the
# guard inspects zero documents and passes. That is indistinguishable from a
# guard that has silently stopped working. This script builds a throwaway git
# repository in a temp directory, replays a pull request for each case below,
# asserts the exit code the guard must return, and fails CI if any is wrong.
#
# The fixtures are test inputs for a linter, not manifests. They exist only
# inside the mktemp directory the trap deletes, are never under clusters/, are
# referenced by no kustomization.yaml, and are reachable by no Application
# path. Nothing here can be deployed.
set -euo pipefail

guard="$(cd "$(dirname "$0")" && pwd)/nodeop_guard.py"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

repo="${work}/repo"
failures=0

good_nodeop() {
  # $1 = metadata.name, $2 = hostname
  cat <<YAML
apiVersion: operator.kairos.io/v1alpha1
kind: NodeOpUpgrade
metadata:
  name: $1
spec:
  image: example.invalid/image:tag
  nodeSelector:
    matchLabels:
      kubernetes.io/hostname: $2
YAML
}

reset_repo() {
  rm -rf "${repo}"
  mkdir -p "${repo}/clusters/demo/apps/thing" "${repo}/base/thing"
  cd "${repo}"
  git init -q -b main
  git config user.email selftest@invalid
  git config user.name selftest
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: tracked\n' \
    > clusters/demo/apps/thing/tracked.yaml
  good_nodeop already-reviewed node-z > clusters/demo/apps/thing/existing.yaml
  printf 'notes\n' > clusters/demo/apps/thing/README.md
  git add -A
  git commit -q -m base
  base="$(git rev-parse HEAD)"
}

run_case() {
  # run_case <want-rc> <label> [want-status]
  # want-status, when given, asserts git actually recorded that status letter —
  # without it a case named "renamed file" can silently degrade into an add and
  # stop exercising the path it claims to cover.
  local want="$1" label="$2" want_status="${3:-}" got=0
  git -C "${repo}" add -A
  git -C "${repo}" diff --name-status -z --diff-filter=ACMRT -M --cached "${base}" \
    > "${work}/changes.z"
  if [ -n "${want_status}" ]; then
    if ! tr '\0' '\n' < "${work}/changes.z" | grep -q "^${want_status}"; then
      echo "SELFTEST FAIL: ${label}: git recorded no ${want_status} status"
      tr '\0' ' ' < "${work}/changes.z" | sed 's/^/    /'
      echo
      failures=$((failures + 1))
      return
    fi
  fi
  ( cd "${repo}" && python3 "${guard}" --changes "${work}/changes.z" --base "${base}" ) \
    > "${work}/out" 2>&1 || got=$?
  if [ "${got}" -ne "${want}" ]; then
    echo "SELFTEST FAIL: ${label}: expected exit ${want}, got ${got}"
    sed 's/^/    /' "${work}/out"
    failures=$((failures + 1))
  else
    echo "selftest ok: ${label}"
  fi
}

# 1. nothing changed
reset_repo
run_case 0 "nothing changed"

# 2. an unrelated YAML document
reset_repo
printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: unrelated\n' \
  > clusters/demo/apps/thing/other.yaml
run_case 0 "non-NodeOp yaml is ignored"

# 3. one node operation, single hostname selector
reset_repo
good_nodeop upgrade-a node-a > clusters/demo/apps/thing/a.yaml
run_case 0 "one node operation, hostname selector"

# 4. two node operations, two new files
reset_repo
good_nodeop upgrade-a node-a > clusters/demo/apps/thing/a.yaml
good_nodeop upgrade-b node-b > clusters/demo/apps/thing/b.yaml
run_case 1 "two node operations in two added files"

# 5. two node operations, one new file
reset_repo
{ good_nodeop upgrade-a node-a; echo '---'; good_nodeop upgrade-b node-b; } \
  > clusters/demo/apps/thing/both.yaml
run_case 1 "two node operations in one added file"

# 6. B1 — two documents appended to an already tracked file
reset_repo
{ echo '---'; good_nodeop upgrade-a node-a; echo '---'; good_nodeop upgrade-b node-b; } \
  >> clusters/demo/apps/thing/existing.yaml
run_case 1 "two node operations appended to a tracked file"

# 7. B1 — one document appended to an already tracked file
reset_repo
{ echo '---'; good_nodeop upgrade-a node-a; } \
  >> clusters/demo/apps/thing/existing.yaml
run_case 0 "one node operation appended to a tracked file"

# 8. B1 — a tracked node operation carried along by an edit elsewhere
reset_repo
printf '# an unrelated trailing comment\n' >> clusters/demo/apps/thing/existing.yaml
run_case 0 "tracked node operation carried unchanged"

# 9. B1 — a tracked node operation whose selector is broken in place
reset_repo
good_nodeop already-reviewed node-z \
  | sed 's|kubernetes.io/hostname: node-z|kairos.io/managed: "true"|' \
  > clusters/demo/apps/thing/existing.yaml
run_case 1 "tracked node operation altered to a bad selector"

# 10. B1 — a rename that changes nothing
reset_repo
git -C "${repo}" mv clusters/demo/apps/thing/existing.yaml \
                    clusters/demo/apps/thing/renamed.yaml
run_case 0 "renamed file, node operation unchanged" R

# 11. B1 — a rename that also breaks the selector. The edit is one line, so the
#     pre- and post-images stay similar enough for git's -M to record a rename
#     rather than a delete plus an add; run_case asserts that it did.
reset_repo
git -C "${repo}" mv clusters/demo/apps/thing/existing.yaml \
                    clusters/demo/apps/thing/renamed.yaml
sed -i.bak 's|kubernetes.io/hostname: node-z|kairos.io/managed: "true"|' \
  clusters/demo/apps/thing/renamed.yaml
rm -f clusters/demo/apps/thing/renamed.yaml.bak
run_case 1 "renamed file, node operation altered to a bad selector" R

# 12. B2 — a node operation in a file with no YAML suffix
reset_repo
good_nodeop upgrade-a node-a > clusters/demo/apps/thing/reboot-node-a
{ echo '---'; good_nodeop upgrade-b node-b; } >> clusters/demo/apps/thing/reboot-node-a
run_case 1 "two node operations in an extensionless file"

# 13. B2 — uppercase suffix
reset_repo
printf 'apiVersion: operator.kairos.io/v1alpha1\nkind: NodeOp\nmetadata:\n  name: u\nspec:\n  command: ["true"]\n' \
  > clusters/demo/apps/thing/Reboot-Node-A.YAML
run_case 1 "no nodeSelector, uppercase .YAML suffix"

# 14. B3 — a node operation outside clusters/
reset_repo
good_nodeop upgrade-a node-a > base/thing/a.yaml
good_nodeop upgrade-b node-b > base/thing/b.yaml
run_case 1 "two node operations under base/"

# 15. no nodeSelector at all
reset_repo
printf 'apiVersion: operator.kairos.io/v1alpha1\nkind: NodeOp\nmetadata:\n  name: n\nspec:\n  command: ["true"]\n' \
  > clusters/demo/apps/thing/a.yaml
run_case 1 "no nodeSelector"

# 16. matchExpressions
reset_repo
printf 'apiVersion: operator.kairos.io/v1alpha1\nkind: NodeOp\nmetadata:\n  name: e\nspec:\n  command: ["true"]\n  nodeSelector:\n    matchExpressions:\n      - key: kubernetes.io/hostname\n        operator: In\n        values: [node-a, node-b]\n' \
  > clusters/demo/apps/thing/a.yaml
run_case 1 "matchExpressions selector"

# 17. two matchLabels
reset_repo
printf 'apiVersion: operator.kairos.io/v1alpha1\nkind: NodeOp\nmetadata:\n  name: t\nspec:\n  command: ["true"]\n  nodeSelector:\n    matchLabels:\n      kubernetes.io/hostname: node-a\n      kairos.io/managed: "true"\n' \
  > clusters/demo/apps/thing/a.yaml
run_case 1 "two matchLabels"

# 18. a selector that is not a hostname
reset_repo
printf 'apiVersion: operator.kairos.io/v1alpha1\nkind: NodeOp\nmetadata:\n  name: w\nspec:\n  command: ["true"]\n  nodeSelector:\n    matchLabels:\n      kairos.io/managed: "true"\n' \
  > clusters/demo/apps/thing/a.yaml
run_case 1 "selector is not a hostname"

# 19. B2 — a file named as YAML that does not parse must fail loudly
reset_repo
printf 'a:\n  - b\n c: [\n' > clusters/demo/apps/thing/broken.yaml
run_case 2 "malformed .yaml is a hard error"

# 20. B2 — a non-YAML text file is skipped in silence
reset_repo
printf 'def f():\n    return {"kind": "NodeOp"}\n' > clusters/demo/apps/thing/script.py
run_case 0 "a python file is skipped"

# 21. B2 — a binary file is skipped in silence
reset_repo
printf '\x00\x01\x02\xff\xfe kind: NodeOp\n' > clusters/demo/apps/thing/blob.bin
run_case 0 "a binary file is skipped"

cd /
if [ "${failures}" -ne 0 ]; then
  echo "nodeop-guard self-test: ${failures} case(s) wrong — the guard is not trustworthy"
  exit 1
fi
echo "nodeop-guard self-test: all 21 cases correct"
