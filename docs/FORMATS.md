# On-disk formats

Deskwork's state is files. Nothing is hidden in a database, nothing needs an API
key, and no part of it is macOS-specific.

That is deliberate. It is what makes a front end in another language a UI
project rather than a rewrite: reimplement these six files and you have the
core. `DeskworkCore` imports nothing but Foundation, and `deskwork-cli` exposes
it as JSON for anything that would rather shell out than reimplement.

```sh
deskwork-cli desks              # configured desks and how each launches
deskwork-cli limits             # remaining quota per vendor
deskwork-cli usage --days 7     # consumption by vendor and by desk
deskwork-cli formats            # every path below, resolved
```

## `~/.config/deskwork/desks.toml`

The desks. `[desk.<name>]` tables; `group` is presentation only; `command`
overrides `runtime` and is run verbatim.

## `~/.config/deskwork/bridge.toml`

```toml
dir   = "~/.local/share/deskwork/mail"   # where threads live
scope = "~/src/api"                      # what the RESPONDER may read
runner = "./ask-claude.sh"               # optional: use your own handoff script
```

`scope` is a privacy boundary, not a convenience. See the README.

## `~/.local/share/deskwork/limits/<vendor>.json`

Remaining quota. **This is the extension point.** Any tool can publish a vendor
Deskwork has never heard of by writing this file; no code change is needed.

```json
{ "vendor": "claude", "weekPct": 3, "weekResetsAt": 1790442000,
  "fiveHourPct": 2, "fiveHourResetsAt": 1789886005,
  "planType": "max", "at": 1789879027.3 }
```

`at` is unix seconds when the reading was taken. Readings are used for 24 hours
and labelled with their age after 20 minutes — an idle vendor is precisely the
one with headroom, so hiding stale readings hides the useful answer. A window
whose `resets_at` has passed is dropped, because that one really is wrong.

Codex needs none of this: it writes quota into its own session rollout and
Deskwork reads it there.

## `~/.local/share/deskwork/sessions/<desk>.json`

Per-desk session state. Context belongs to a session, not a vendor.

```json
{ "desk": "hub", "ctxPct": 63, "model": "Claude Opus 5",
  "effort": "xhigh", "usd": 540.10, "at": 1789879027.3 }
```

Stale after 15 minutes, unlike quota. Context only moves while the desk is
working, so an old reading describes a conversation that has since grown.

## `~/.local/share/deskwork/mail/thread-<a>-<b>.md`

The cross-vendor thread. Append-only markdown, `## <who> · <timestamp>` per
turn. The whole file is sent as context on every ask, which is why it must
never be rewritten in place.

## `~/.config/deskwork/ui.json`

Window state: collapsed groups, tree position. Safe to delete.

## Consumption, read from the vendors

Not written by Deskwork; read from what the CLIs already keep.

| vendor | path | record |
|---|---|---|
| Claude | `~/.claude/projects/<proj>/<session>.jsonl` | `message.usage`; **deduplicate on `message.id`** |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `type: token_usage_record`, and `payload.rate_limits` for quota |

The dedupe is not optional. A streamed reply is written to the Claude
transcript more than once; counting every record roughly doubles the total.
