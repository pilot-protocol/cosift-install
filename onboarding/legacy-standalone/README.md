# Legacy standalone onboarding installer

Preserved from `services/cosift-onboarding`, a working tree that was never committed
anywhere. T4 shipped the interview as a standalone artifact with its own installer,
`bin/install-onboarding.sh`; on 2026-09-17 that was dissolved into `install.sh`, which
carries the generated artifacts as heredocs instead.

Kept here because these are the only copies that exist:

- `bin/install-onboarding.sh` — the standalone installer
- `tests/container/` — the tier-B rig: a throwaway-HOME image that installs the real
  vendor CLIs and asserts install mechanics against them
- `tests/shell/cases/50-install.sh` — the tier-A case covering install, dry-run, force
  and uninstall for that installer

Deliberately **not** under `onboarding/tests/`: `onboarding/tests/shell/run.sh`
auto-discovers every `cases/*.sh`, and `50-install.sh` targets a script this repo no
longer ships, so discovering it would fail `make check`. Nothing here runs in CI. The
live coverage for the shipped path is the 58-case matrix in `tests/`.
