# crew

Crew is a general tool for running a fleet of role-focused coding agents. The
engine ships in this repository; the fleet definition belongs to the operator.
An operator can initialize a definition, edit it outside the checkout, and run
the same upstream engine without maintaining a fork:

```sh
crew init
$EDITOR "${XDG_CONFIG_HOME:-$HOME/.config}/crew/fleet.roster"
$EDITOR "${XDG_CONFIG_HOME:-$HOME/.config}/crew/repos.txt"   # ships EMPTY — name your repos
crew up
```

`crew init` is not optional. Without an operator definition crew falls back to
the shipped `examples/` directory, and there it refuses to create a box or arm
cron — it will only report, and it says so on every read-only verb. A scaffold
is a thing to read, not a fleet to run, so `repos.txt` ships empty and the
fleet is aimed at nothing until you name a repository (#216).

The operator definition owns fleet membership, participants, repository scope,
agent profiles, and the doctrine paths named in prompts. Shipped files under
`examples/` are compatibility defaults and scaffolding, not heavy-duty policy
compiled into the engine.

A new agent profile is configuration. A new role changes the engine and its
duty lifecycle; see [#71](https://github.com/heavy-duty/crew/issues/71) for
that boundary.

`crew init [config-dir]` creates `fleet.roster`, `fleet.conf`, `repos.txt`,
`notify-repos.txt`, `doctrine.conf`, and an optional `agents/` directory. It
never overwrites an existing path. Its login list is a static reading of every
roster row; live authentication remains a manual, per-box step reported by
`crew up`.

Operator agent profiles resolve today: a profile in the config dir's
`agents/` is found by every reader (`crew profiles`, `crew new`, the console),
wins over a same-named shipped profile, and is transported to the box before
`install.sh` validates it — so a box can be hired with a vendor CLI crew has
never shipped, without forking the tree. The precedence is the point: an
operator `claude.conf` beats the shipped one, or a fleet could never adjust a
vendor it did not invent.

## Install

Every channel runs the same `install.sh`, which lays `crew` out under
`~/.local/share/crew/versions/<version>/`, points `current` at one, and links
`~/.local/bin/crew` through it, so releases coexist and `crew use` switches
between them.

- **From a checkout** — clone the repo and run `cli/crew` (put it on `PATH`, or
  call it directly). This is the mode a second operator adopts today: clone,
  `crew init`, edit the fleet definition, `crew up`.

- **From the scp-able artifact** — *primary; offline, no `gh`, no `curl`, no
  network.* Each release publishes `crew-<version>.sh`: a stub with the whole
  tree appended, small enough to email
  ([#98](https://github.com/heavy-duty/crew/issues/98)), and
  `crew-<version>.sh.sha256` beside it. Copy it to the target and run it:

  ```sh
  scp crew-<version>.sh box:/tmp/     # or a USB stick, or a chat paste
  ./crew-<version>.sh                 # verifies its checksum, then installs
  ./crew-<version>.sh --check         # verify only, install nothing
  ./crew-<version>.sh --version       # identify the file without running it
  sha256sum -c crew-<version>.sh.sha256   # check the download against the release
  ```

  It verifies the payload's sha256 **before** unpacking, so a truncated or
  mangled copy refuses with a re-copy instruction before anything is written.
  `dist/make-installer.sh` builds one from any tree.

- **From a local tree or tarball** — CI and the drill install the code under
  review directly:

  ```sh
  CREW_INSTALL_SOURCE=<a crew tree or tarball> bash install.sh
  ```

- **Via `gh`** — a convenience where an authenticated `gh` is already present:
  `dist/fetch.sh [--ref latest|TAG]` resolves a release and fetches its source
  tarball through `gh` (uses the caller's existing credentials, no anonymous
  URL), then installs it.

<!-- BEGIN github-hosted channel (#171) — delete this block when crew moves off GitHub -->
- **Via `curl | bash`** — anonymous, no `gh` and no token. **This channel exists
  only while crew is hosted on GitHub**, and is removed when crew moves off it
  after `0.1.0`:

  ```sh
  curl -fsSL https://raw.githubusercontent.com/heavy-duty/crew/main/dist/curl-install.sh | bash
  CREW_REF=0.1.0 curl -fsSL … | bash   # that release, instead of the latest
  CREW_REF=main  curl -fsSL … | bash   # the development tip, a -dev version
  ```

  Unset, `CREW_REF` means the latest published release, resolved off GitHub's
  own `releases/latest` redirect — so the same command installs the same crew
  for everyone. If it cannot resolve one it refuses and says so; it never falls
  back to `main` behind your back. It asks before downloading anything, and
  `CREW_INSTALL_SOURCE` still short-circuits the network entirely.
<!-- END github-hosted channel (#171) -->


`install.sh` installs per user for a non-root caller and into `/opt/crew` plus
`/usr/local/bin` for root, so a shared host can carry one system tree. The tree
does not choose an operator: crew runs as its caller, box resolves that caller's
tier, and fleet configuration remains in that caller's home. Re-running the same
version changes nothing; a new version becomes the default and names the hired
boxes to converge onto it with `crew upgrade --all` (it names them; it does not
inspect each box's engine version). `CREW_HOME` / `CREW_BIN` override either
layout; `CREW_YES=1` drives it non-interactively.

See [examples/README.md](examples/README.md) for configuration discovery and
file ownership, and [shared/README.md](shared/README.md) for engine internals.
