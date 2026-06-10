import ast
from pathlib import Path

import aiofastnet


def test_public_exports_have_stubs():
    stub = ast.parse(
        Path(aiofastnet.__file__).with_name("__init__.pyi").read_text()
    )
    stub_names = set()

    for node in stub.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            stub_names.add(node.name)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            stub_names.add(node.target.id)
        elif isinstance(node, ast.ImportFrom):
            stub_names.update(alias.asname or alias.name for alias in node.names)

    assert set(aiofastnet.__all__) <= stub_names
