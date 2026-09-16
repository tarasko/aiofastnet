# Releasing aiofastnet

This document describes the maintainer workflow for publishing aiofastnet to PyPI and creating the corresponding GitHub Release.

## Prepare the release

1. Create a branch release/1.2.0
2. Ensure every user-visible change is described under `Unreleased` in `CHANGES.md`. 
3. Choose the new version and update `__version__` in `aiofastnet/version.py`.
4. Finalize the changelog using the same version without the `v` tag prefix:

   ```console
   $ python tools/changelog.py prepare 1.2.0
   ```

   This moves the contents of `Unreleased` into a new `## 1.2.0` section and leaves a new empty `Unreleased` section for subsequent changes. The
   command fails if `Unreleased` is empty or the version already exists.

5. Review the resulting changelog and run the relevant checks:

   ```console
   $ ruff check .
   $ pytest -n auto -v
   ```

6. Commit the version and changelog changes, create PR, wait for its required checks to pass, merge PR.

## Publish the release

Create an annotated tag from the merged release commit and push it:

```console
$ git switch master
$ git pull --ff-only
$ git tag -a v1.2.0 -m "Release 1.2.0"
$ git push origin v1.2.0
```

The tag version must match both `aiofastnet/version.py` and the finalized heading in `CHANGES.md`.

Pushing a `v*` tag starts `.github/workflows/release.yml`. The workflow:

1. Extracts the matching version section from `CHANGES.md`. Missing or empty notes prevent publishing.
2. Builds the source distribution and platform wheels.
3. Publishes all distributions to PyPI through the `pypi` environment and Trusted Publishing.
4. Signs the distributions with Sigstore after PyPI publishing succeeds.
5. Creates the GitHub Release.
6. Uses the extracted changelog section verbatim as the GitHub Release description and attaches all distributions and Sigstore bundles to the
   release.

PyPI generates Sigstore-backed attestations for the published distributions automatically.

## Verify the release

After the workflow completes:

- Confirm that the expected version and distributions are present on PyPI.
- Confirm that the GitHub Release contains the same notes as `CHANGES.md` and includes the source distribution, all wheels, and their Sigstore
  bundles.
- Install the new version in a clean environment and verify that `aiofastnet.__version__` reports the expected value.

## Failed releases

- For a transient workflow failure, rerun the failed job.
- If PyPI publishing succeeded but GitHub Release creation failed, rerun the `github-release` job. Do not create a new tag.
- If any distribution reached PyPI, do not move or reuse the version tag. Correct the problem in a new release because published PyPI files are
  immutable.
- If publishing did not begin and the release commit itself is wrong, correct the release commit before publishing. Avoid changing a tag that users
  may already have fetched.
