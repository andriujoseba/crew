# Fleet configuration

`crew` selects one fleet directory, never a mixture of files from several
directories. Search order is:

1. `CREW_CONFIG_DIR` (authoritative; an invalid value is an error)
2. `$XDG_CONFIG_HOME/crew`, or `~/.config/crew` when XDG is unset
3. the directory where `crew` was invoked
4. this shipped example directory

`fleet.roster` is the proof file. `fleet.roster`, `fleet.conf`, and `repos.txt`
are required together in whichever directory is selected — this one included;
crew never borrows another fleet's participants or repository scope. Optional
behaviour files fall back to the matching file in this directory.

## This directory is not an operator definition

Step 4 is a **fallback**, and reaching it means nobody has configured this
host. crew says so and then does nothing irreversible (#216):

- **Mutating verbs refuse.** `new`, `create-all`, `hire`, `hire-all`, `up`,
  `down`, `upgrade` and `gold` exit non-zero naming `crew init`. Creating
  boxes and arming cron against a definition the operator never wrote is how
  an unconfigured host becomes a fleet aimed at somebody else's repositories.
- **`crew floor` refuses too**, in both processes — the CLI and `floor.py` run
  directly (#244). The console's buttons resume cron and start model sessions,
  so it belongs to the class above however much it reads like a view, and a
  `--roster` does not lift the refusal: that selects a roster file, not a
  fleet. `crew status` is the inspection surface on a host in this state.
- **Read-only verbs keep working**, because inspecting an unconfigured host is
  exactly what they are for. `crew status`, `crew profiles` and
  `crew up --dry-run` print a banner on stderr naming this directory as the
  source and stating it is not an operator definition.
- **`repos.txt` here ships empty**, so even a mis-copied scaffold is aimed at
  nothing, and `fleet.conf`'s identities are illustrations marked REPLACE ME.

`crew init` seeds a new operator directory from these files; the seeded
registry is empty and the fleet stays aimed at nothing until the operator
names a repository.

```text
fleet.roster       box name, agent and role
fleet.conf         operator fleet values
repos.txt          seed for a new box's work registry
notify-repos.txt   additive cross-repo notification targets for a new triage box
agents/*.conf      optional operator agent profiles; same name overrides shipped
doctrine.conf      optional doctrine paths named in rendered prompts
```

The host atomically replaces `fleet.roster` and `fleet.conf` in a box on every
hire or upgrade. Registries follow the host only while their box copy remains
untouched. A divergent registry vetoes replacement and is named loudly.

`doctrine.conf` is resolved on the host and rides inside the staged runtime
`fleet.conf`; it does not require another box-side configuration file. Its
values are repository-relative paths used in prompts. Omitting it preserves
the shipped `AGENTS.md`, `TRIAGE.md`, `BUILDER.md`, and `REVIEWER.md` names.

`CREW_ROSTER` remains a roster-only override for drills and fixtures. It takes
precedence over the selected directory's roster but does not select a different
fleet context.
