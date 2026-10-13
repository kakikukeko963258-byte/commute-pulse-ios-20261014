"""Optional grammar-only check. Does not invoke Swift/Xcode or type-check APIs.

python -m pip install --only-binary=:all: --target .tools tree-sitter tree-sitter-swift PyYAML
python Scripts/check_swift_syntax.py
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / ".tools"))
import tree_sitter_swift
from tree_sitter import Language, Parser
import yaml

parser = Parser(Language(tree_sitter_swift.language()))
count = 0
errors = []
files = [ROOT / "Package.swift"] + list(ROOT.glob("Sources/**/*.swift")) + list(ROOT.glob("Tests/**/*.swift"))
for path in files:
    tree = parser.parse(path.read_bytes())
    stack = [tree.root_node]
    while stack:
        node = stack.pop()
        if node.type == "ERROR" or node.is_missing:
            errors.append(f"{path.relative_to(ROOT)}:{node.start_point.row + 1}: {node.type}")
        stack.extend(node.children)
    count += 1
if errors:
    raise SystemExit("\n".join(errors))
for path in [ROOT / "project.yml"] + list(ROOT.glob(".github/workflows/*.yml")):
    # BaseLoader avoids YAML 1.1 treating the GitHub 'on' key as a boolean.
    parsed = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    if ".github" in path.parts:
        assert list(parsed["on"]) == ["workflow_dispatch"]
    else:
        assert set(parsed["targets"]) == {"CommutePulse", "CommutePulseWidgets"}
print(f"Swift grammar: PASS ({count} files); YAML parsing: PASS")
print("This is syntax scanning only. Swift type checking, compilation and XCTest were NOT RUN.")
