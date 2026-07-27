# Fleet configuration

`crew` selects one fleet directory, never a mixture of files from several
directories. Search order is:

1. `CREW_CONFIG_DIR` (authoritative; an invalid value is an error)
2. `$XDG_CONFIG_HOME/crew`, or `~/.config/crew` when XDG is unset
3. the directory where `crew` was invoked
4. this shipped example directory

`fleet.roster` is the proof file and is required. The other files are optional;
when absent, the matching file in this directory supplies the compatibility
default.

```text
fleet.roster       box name, agent and role
fleet.conf         operator fleet values
repos.txt          seed for a new box's work registry
notify-repos.txt   seed for a new triage box's wider notification registry
agents/*.conf      optional operator agent profiles (reserved)
doctrine.conf      optional doctrine paths (reserved)
```

The host atomically replaces `fleet.roster` and `fleet.conf` in a box on every
hire or upgrade. Registry files seed a missing box-local file once and are
never used to overwrite it.

`CREW_ROSTER` remains a roster-only override for drills and fixtures. It takes
precedence over the selected directory's roster but does not select a different
fleet context.
