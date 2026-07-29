#!/usr/bin/env sh
# Assemble a self-contained, dependency-free index.html from src/.
# No build tools, no network, no external assets — just concatenation.
set -eu
cd "$(dirname "$0")"
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n'
  printf '<meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
  printf '<title>Fleet Floor</title>\n'
  printf '<style>\n'
  cat src/style.css
  printf '\n</style>\n</head>\n<body>\n'
  cat src/body.html
  printf '<script>\n'
  cat src/app.js
  printf '\n</script>\n</body>\n</html>\n'
} > index.html
echo "built index.html ($(wc -c < index.html) bytes)"

# dev/whiteboard.html — the asset map: every agent x room x state on one page.
# It is the SAME src/, plus a grid: the robots and rooms it shows are drawn by
# src/app.js's own drawTarget through the FLOORDEV hook, never by a second copy
# of the art. That is what makes it worth screenshotting — an asset map that
# owned its own renderer would agree with the app only until either changed.
{
  printf '<!doctype html>\n<html lang="en">\n<head>\n'
  printf '<meta charset="utf-8">\n'
  printf '<title>Fleet Floor · asset map</title>\n'
  printf '<style>\n'
  cat src/style.css
  cat dev/whiteboard.css
  printf '\n</style>\n</head>\n<body>\n'
  cat src/body.html
  printf '<div id="wb"></div>\n'
  # BEFORE app.js, and it must stay that way: app.js builds the film-grain
  # texture, the motes, the steam and the floor haze at module load, so a PRNG
  # installed after it is already too late for all four.
  printf '<script>\n'
  cat dev/seed.js
  printf '\n</script>\n<script>\n'
  cat src/app.js
  printf '\n</script>\n<script>\n'
  cat dev/whiteboard.js
  printf '\n</script>\n</body>\n</html>\n'
} > dev/whiteboard.html
echo "built dev/whiteboard.html ($(wc -c < dev/whiteboard.html) bytes)"
