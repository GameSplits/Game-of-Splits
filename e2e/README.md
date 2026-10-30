# Keeper + watcher end to end (local fork only)

`bash e2e/keeper_watcher.sh` from the repo root (Foundry 1.5.x on PATH or `FOUNDRY_BIN`; Node 22).

- Needs the **whole repo**: `contracts/` as a full Foundry project (src, test, script, lib submodules: run
  `git submodule update --init --recursive` or `forge install`), plus `keeper/` and `watcher/`. It copies `contracts/` to
  a temp dir and deploys from there, so it never writes deployment files into the repo.
- Starts its own anvil fork of the public Robinhood Chain mainnet RPC, refuses to run against anything that isn't anvil,
  makes a throwaway keeper key, and creates a real multisig SafeL2 (`contracts/script/e2e/make_safe.sh`) that executes one
  no-op tx so it passes the deploy's Safe check. Nothing is sent to a real chain; no secrets are used.
- `E2E_PORT` (default 8790) is the local watcher port; `E2E_DEBUG=1` prints the front-run sizing.
