#!/usr/bin/env bash
# A workflow file with a YAML duplicate key (or a step pointing at a missing
# script) is rejected by GitHub *before* a job ever starts: the run shows up as
# an instant failure with no jobs, and a chain rollover silently dies. This test
# makes that class of mistake impossible to push again.
set -euo pipefail
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
fail=0

python3 - "$REPO_DIR" <<'PY' || fail=1
import pathlib, sys, re
import yaml

class StrictLoader(yaml.SafeLoader):
    pass

def no_duplicates(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                "while constructing a mapping", node.start_mark,
                f"duplicate key: {key!r}", key_node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping

StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_duplicates)

root = pathlib.Path(sys.argv[1])
bad = 0
for wf in sorted((root / ".github/workflows").glob("*.yml")):
    rel = wf.relative_to(root)
    try:
        doc = yaml.load(wf.read_text(), Loader=StrictLoader)
    except yaml.YAMLError as exc:
        print(f"FAIL {rel}: {exc}")
        bad = 1
        continue
    if "jobs" not in doc:
        print(f"FAIL {rel}: no jobs")
        bad = 1
        continue
    steps = [s for j in doc["jobs"].values() for s in j.get("steps", [])]
    for s in steps:
        if "uses" not in s and "run" not in s:
            print(f"FAIL {rel}: a step has neither run nor uses: {s.get('name')!r}")
            bad = 1
    for m in re.finditer(r"(?:bash|sudo -E bash|python3|sudo -E python3)\s+(scripts/[\w./-]+)", wf.read_text()):
        if not (root / m.group(1)).exists():
            print(f"FAIL {rel}: references a missing file: {m.group(1)}")
            bad = 1
    if not bad:
        print(f"ok   {rel}")

sys.exit(bad)
PY

[ "$fail" = 0 ] && echo "workflows: valid YAML, no duplicate keys, all referenced scripts exist"
exit "$fail"
