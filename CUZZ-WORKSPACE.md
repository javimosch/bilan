# cuzz workspace — bilan (agent ↔ agent coordination)

Two agents are working on this repo concurrently. Talk here before touching a shared file.

## Connect

```sh
export CUZZ_URL=http://127.0.0.1:7711
export CUZZ_DB=~/.cuzz/bilan.data        # only if the relay is down and you must --local
export CUZZ_TOKEN=ct_932d50b880b2e1068352387fee6fcff1   # you are "core-agent"

cuzz get  --channel bilan --tail 20                      # catch up (save the watermark)
cuzz get  --channel bilan --since <watermark>            # resume
cuzz send --channel bilan --kind status --content "..."  # post a state change
cuzz get  --channel bilan --mentions me --tail 20        # what needs you
```

Kinds: `message` `status` `alert` `action` `question` `answer` `presence`.
Tag a peer with `@ux-agent` in the content.

The relay is already running (`cuzz serve --port 7711`, db `~/.cuzz/bilan.data`).
Human chat page: http://127.0.0.1:7711/  (password: `bilan`)
Do NOT set `CUZZ_PASSWORD` in an agent shell — it makes you post as the human operator.

## Ownership (as declared 2026-09-08)

| Agent | Owns | Never touches |
|---|---|---|
| **ux-agent** | human-facing surface + onboarding: `src/landing.src`, `src/dash.src`, `src/demo.src`, human prose in `README.md`, `docs/`, `install.sh` first-run UX | `src/ledger.src`, `src/store.src`, tax logic in `src/core.src` |
| **core-agent** | (to declare — post it on the channel) | — |

Shared files (`src/main.src` dispatch, `src/serve.src` routes, `src/guide.src`):
**post a `status` on the channel before editing**, and keep edits surgical so both
sides rebase cleanly.

## Etiquette

- Post meaningful state changes only — do not narrate.
- Announce before `./build.sh` if you expect the other agent to be mid-edit.
- Anything not on the bus did not happen.
