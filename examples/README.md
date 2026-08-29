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
fleet.roster              box name, agent and role
fleet.conf                operator fleet values
repos.txt                 seed for a new box's work registry
notify-repos.txt          additive cross-repo notification targets for a new triage box
repos.d/<box>.txt         optional per-box selection from repos.txt
notify-repos.d/<box>.txt  optional per-box selection from notify-repos.txt
agents/*.conf             optional operator agent profiles; same name overrides shipped
doctrine.conf             optional doctrine paths named in rendered prompts
```

## Narrowing one box

A `.d` file **selects** from the fleet-wide list for the box it names: the box
carries those repositories and nothing else. The host stages the selection in
place of the fleet-wide registry at every hire and upgrade, so narrowing one
droid to a single board is one file, not an edit to a list every other box
reads too.

**A box can only watch repositories the fleet watches.** The `.d` file names a
subset of the fleet-wide list and never reaches outside it. That bound is held
in two places, and it has to be both: an entry the fleet-wide list does not
name is refused when it is written, and the selection is intersected with the
fleet-wide list again on every read — so retiring a repository fleet-wide takes
it off the boxes that had selected it, instead of leaving them working a board
the fleet no longer knows about. A narrowed box is a box doing what it was
asked; nothing reads it as diverged.

**Existence is the whole test** for *having* a selection. An *empty* file is a
box deliberately aimed at no board at all — the narrowing `repos.txt`'s own
header describes — and not a box that has no selection. **Removing** the file
is how a box goes back to inheriting, and that is a different act from writing
today's fleet-wide list into it: the box that inherits follows a later
widening, the box pinned to a copy of it does not.

Both files are edited by hand, and by `crew floor` — which validates before it
writes and records every write in `.registry-journal.log` beside them. The two
scopes refuse different things, because they are asked different questions: a
fleet-wide edit refuses a repository the fleet cannot reach, since its entries
are new to the fleet, while a `.d` edit refuses one the fleet-wide list does
not name and asks nothing of GitHub, since none of its entries can be new.
Neither reader caches: a hand edit is picked up by the next tick and by the
console without a restart.

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
