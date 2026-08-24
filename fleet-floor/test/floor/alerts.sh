# shellcheck shell=bash  # sourced by ../run.sh, so it has no shebang of its own
# fleet-floor/test/floor/alerts.sh — the suite for fleet-floor/server/floor/alerts.py.
#
# Both files are empty, and deliberately so. #508's D1 draws the seam that
# #481 fills — the floor sees a dead box and tells nobody who is not looking at
# the page — and D2 says the suite tree mirrors the source tree. The mirror is
# drawn here at the same moment, so #481 is an edit to two named files rather
# than a decision about where its assertions go.
#
# It asserts nothing because there is nothing to assert yet: inventing a case
# for behaviour this PR did not add would be the rewrite D5 forbids, and a
# passing assertion about an empty module is worse than no file at all.
