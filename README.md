# crew

Crew is a general tool for running a fleet of role-focused coding agents. The
engine ships in this repository; the fleet definition belongs to the operator.
An operator can initialize a definition, edit it outside the checkout, and run
the same upstream engine without maintaining a fork:

```sh
crew init
$EDITOR "${XDG_CONFIG_HOME:-$HOME/.config}/crew/fleet.roster"
crew up
```

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

See [examples/README.md](examples/README.md) for configuration discovery and
file ownership, and [shared/README.md](shared/README.md) for engine internals.
