## Description

Read README.md for project description.

# Code style

* Max line width: 150
* Do not add over-defensive guards for impossible or unsupported states. If a
  required API should exist in the tested/supported path, call it directly and
  let failures surface. Only catch exceptions when the code has a concrete,
  expected recovery path.

# Verification

* Run `ruff check .` after code changes.
* `mypy` should pass at least for Python 3.9.
