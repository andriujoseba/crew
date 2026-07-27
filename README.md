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

Operator agent-profile overrides are scaffolded for forward compatibility.
Their runtime resolution is tracked separately in
[#75](https://github.com/heavy-duty/crew/issues/75).

See [examples/README.md](examples/README.md) for configuration discovery and
file ownership, and [shared/README.md](shared/README.md) for engine internals.
