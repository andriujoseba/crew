# changelog.d/ — the next release's section, one fragment per issue

Every PR that changes behavior writes one file here — `<issue>.md`, the exact
prose that will be published, nothing else — and the release PR folds them all
into the next `## X.Y.Z — DATE` section of `CHANGELOG.md`, consuming them.
Distinct filenames never conflict, which is this directory's whole reason to
exist. This README is the marker that keeps the directory tracked when it holds
no fragments — `changelog-armed` refuses a tree without it; do not delete it.

The machinery — the assembler and the guards — is consumed by reference from
heavy-duty/ceremony (pinned in `.github/workflows/release.yml`), not vendored
here.
