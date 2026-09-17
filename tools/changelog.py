"""Prepare and extract entries from CHANGES.md."""

import argparse
import re
import sys
from pathlib import Path

UNRELEASED_HEADING_RE = re.compile(r"^## Unreleased[ \t]*$", re.MULTILINE)
LEVEL_TWO_HEADING_RE = re.compile(r"^## .+$", re.MULTILINE)
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")


class ChangelogError(Exception):
    """Raised when the changelog does not have the expected structure."""


def _validate_version(version: str) -> None:
    if not VERSION_RE.fullmatch(version):
        raise ChangelogError(f"invalid version: {version!r}")


def _find_single_heading(text: str, pattern: re.Pattern) -> re.Match:
    matches = list(pattern.finditer(text))
    if not matches:
        raise ChangelogError("required changelog section was not found")
    if len(matches) > 1:
        raise ChangelogError("changelog section appears more than once")
    return matches[0]


def _section_body(text: str, heading: re.Match) -> tuple[str, int]:
    next_heading = LEVEL_TWO_HEADING_RE.search(text, heading.end())
    section_end = next_heading.start() if next_heading else len(text)
    return text[heading.end():section_end].strip(), section_end


def _has_release_note(body: str) -> bool:
    return any(line.strip() and not line.lstrip().startswith("#") for line in body.splitlines())


def prepare_changelog(path: Path, version: str) -> None:
    """Move the Unreleased notes into a version section."""
    _validate_version(version)
    text = path.read_text(encoding="utf-8")

    version_heading_re = re.compile(rf"^## {re.escape(version)}[ \t]*$", re.MULTILINE)
    if version_heading_re.search(text):
        raise ChangelogError(f"version {version} already exists in {path}")

    unreleased_heading = _find_single_heading(text, UNRELEASED_HEADING_RE)
    body, section_end = _section_body(text, unreleased_heading)
    if not _has_release_note(body):
        raise ChangelogError("the Unreleased section has no release notes")

    replacement = f"## Unreleased\n\n## {version}\n\n{body}\n\n"
    updated = text[:unreleased_heading.start()] + replacement + text[section_end:]
    path.write_text(updated.rstrip() + "\n", encoding="utf-8")


def extract_release_notes(path: Path, version: str) -> str:
    """Return the body of a version section for use as release notes."""
    _validate_version(version)
    text = path.read_text(encoding="utf-8")
    heading_re = re.compile(rf"^## {re.escape(version)}[ \t]*$", re.MULTILINE)
    heading = _find_single_heading(text, heading_re)
    body, _ = _section_body(text, heading)
    if not _has_release_note(body):
        raise ChangelogError(f"version {version} has no release notes")
    return body + "\n"


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changelog", type=Path, default=Path("CHANGES.md"))
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare_parser = subparsers.add_parser("prepare", help="finalize the Unreleased section")
    prepare_parser.add_argument("version")

    extract_parser = subparsers.add_parser("extract", help="print a version's release notes")
    extract_parser.add_argument("version")
    extract_parser.add_argument("--output", type=Path)
    return parser


def main(argv=None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)

    try:
        if args.command == "prepare":
            prepare_changelog(args.changelog, args.version)
            print(f"Prepared {args.version} in {args.changelog}")
        else:
            notes = extract_release_notes(args.changelog, args.version)
            if args.output:
                args.output.write_text(notes, encoding="utf-8")
            else:
                sys.stdout.write(notes)
    except (ChangelogError, OSError) as exc:
        parser.exit(1, f"error: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
