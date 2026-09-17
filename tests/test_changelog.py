import pytest

from tools.changelog import ChangelogError, extract_release_notes, prepare_changelog

CHANGELOG = """\
# Changelog

## Unreleased

### Added

- A useful feature.

### Fixed

- A surprising bug.

## 1.0.0

- The initial release.
"""


def test_prepare_and_extract_changelog(tmp_path):
    path = tmp_path / "CHANGES.md"
    path.write_text(CHANGELOG)

    prepare_changelog(path, "1.1.0")

    assert path.read_text() == """\
# Changelog

## Unreleased

## 1.1.0

### Added

- A useful feature.

### Fixed

- A surprising bug.

## 1.0.0

- The initial release.
"""
    assert extract_release_notes(path, "1.1.0") == """\
### Added

- A useful feature.

### Fixed

- A surprising bug.
"""


def test_prepare_rejects_empty_unreleased_section(tmp_path):
    path = tmp_path / "CHANGES.md"
    path.write_text("# Changelog\n\n## Unreleased\n\n## 1.0.0\n\n- Initial release.\n")

    with pytest.raises(ChangelogError, match="no release notes"):
        prepare_changelog(path, "1.1.0")


def test_extract_rejects_missing_version(tmp_path):
    path = tmp_path / "CHANGES.md"
    path.write_text(CHANGELOG)

    with pytest.raises(ChangelogError, match="not found"):
        extract_release_notes(path, "2.0.0")
