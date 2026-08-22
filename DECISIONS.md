# DECISIONS.md

Running log of notable changes to this fork and why they were made. Reverse-chronological. For a structural overview of the repo, see [CLAUDE.md](CLAUDE.md).

## 2026-08-22 — Remove unused `LS_MEM_LIMIT` from `.env`

What: Dropped the `LS_MEM_LIMIT` variable from `.env`.

Why: Logstash was removed from this stack a while back since it isn't core to this project, but the env var was left behind with no service left to read it. Caught during Rowan's (Elastic Stack engineer) first stack review.

## 2026-08-07 — Add `app-noisy` for an APM trace study

What: New `noisy-app` service (`app-noisy/`) that builds deeply nested JSON/XML documents and walks them with either one APM span per node or one aggregate span per operation (`mitigated` toggle), runnable via sliders in a small NiceGUI page.

Why: Wanted a controllable reproduction of the "excessive/low-value nested spans" APM anti-pattern to study its effect on trace volume and readability, and to compare it against the mitigated instrumentation pattern side by side.

## 2026-08-07 — Sync ES/Fleet CA on startup

What: `scripts/elastic-with-vault.sh up` now pushes the current `certs` volume's CA into Fleet's default output on every run.

Why: The `certs` volume's CA regenerates whenever it's recreated (e.g. `docker compose down -v`), which was silently breaking fleet-server's TLS trust of `es01` with no obvious config drift. Re-syncing on every `up` keeps the trusted CA in Fleet's output matched to what's actually in use.

## 2026-08-06 — Add Vault-backed secrets management

What: Added a `vault` service to `docker-compose.yml`, plus `scripts/elastic-with-vault.sh` and `scripts/vault-add-consumer.sh`. `elastic`/`kibana_system` passwords are now generated once and stored in Vault (`secret/elastic`) rather than a plaintext `.env` value, accessed via a least-privilege `elastic-stack` AppRole. The Vault root token and unseal key never touch disk — they're captured straight into the macOS Keychain on first `vault operator init` and used only once to bootstrap the AppRole; routine runs authenticate via the AppRole.

Why: Avoid plaintext credentials in `.env`/shell history for a stack that's otherwise meant to mirror a more production-realistic secrets flow, and make it straightforward to onboard additional least-privilege consumers later.

---

Append new entries at the top when making a notable change — this is a running log, not retroactive documentation.
