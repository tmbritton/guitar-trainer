# Epic 6 / Story 6.8 — Toolchain: project-scoped Python + portable build

**Goal:** Importing a song failed with "demucs not found". Fix that properly —
manage Python the way Odin is already managed (pinned by mise, contained to the
project), and stop the build documentation from assuming one host.

**Key idea:** mise already pins the Odin toolchain; it can pin Python and own a
project virtualenv too, so nothing is installed system-wide and a fresh clone
reproduces the same versions.

## What changed

- **`mise.toml`** — pins `python = "3.13.15"` beside `odin`; declares the venv
  via `[env] _.python.venv = { path = ".venv", create = true, uv_create_args =
  ["--seed"] }`; adds tasks `setup-python`, `lock-python`, `check-python`.
- **`requirements.txt` / `requirements.lock.txt`** — direct deps (`demucs`,
  `numpy`, later `mutagen`, `soundfile`) and a full 52-package freeze that
  `setup-python` installs.
- **`src/import.odin`** — resolves `./.venv/bin/python3` directly (falling back
  to PATH) so importing works when the binary wasn't launched from a
  mise-activated shell; error text now points at `mise run setup-python`.
- **`src/app.odin`** — `rl.SetExitKey(.KEY_NULL)` after window setup.
- **Docs** — `CLAUDE.md` / `README.md` / `build.sh` / `test.sh` made
  host-agnostic.
- **`~/dotfiles/zsh/.zshrc`** (outside the repo) — `eval "$(mise activate zsh)"`.

## Steps

- [x] **Step 1:** pin Python in `mise.toml`; declare the project venv.
- [x] **Step 2:** install deps; lock them.
- [x] **Step 3:** resolve the venv interpreter from `import.odin`.
- [x] **Step 4:** disable raylib's ESC exit key; audit every screen for a
      per-screen ESC handler so nothing becomes a dead end.
- [x] **Step 5:** de-host the build docs; verify a missing `BREW_LIB` is inert.

## Verification

- `mise run check-python` → `demucs 4.1.0 | torch 2.13.0+cu130 | numpy 2.3.4 |
  cuda True` — GPU inference available.
- All `separate.py` real-mode imports resolve.
- `./build.sh`, `./test.sh` (all packages), `--importcheck` pass.
- mise's Python toolchain confirmed clean afterwards (site-packages holds only
  `pip`).
- ESC: all 7 `Screen` values audited for a handler — `Main_Menu` quits, the rest
  go back, `Importing`/`Player` clean up on the way out. Behaviour itself is a
  manual check (needs the GUI).

## Notes / risks

- **`uv_create_args = ["--seed"]` is load-bearing.** mise builds the venv with
  `uv`, and a bare `uv venv` ships no `pip`. Without the seed, `pip` inside an
  activated shell resolves to the *mise toolchain's* pip and installs there:
  4.8 GB of CUDA wheels landed in
  `~/.local/share/mise/installs/python/3.13.15` before this was caught. It fails
  silently — `pip install` reports success.
- **demucs 4.1.0 does not declare numpy** although `demucs/transformer.py`
  imports it, so `pip install demucs` alone yields a venv that fails at import.
  Pinned explicitly in `requirements.txt`.
- The venv only activates under `mise activate` / `mise exec` — **not** via
  shims. Hence the direct `.venv/bin/python3` resolution in `import.odin`.
- Odin shells out to **`clang` as its linker driver on every platform**;
  `-linker:lld` / `-linker:mold` only append `-fuse-ld=` and do not avoid it.
- Follow-up: the separator paths are still cwd-relative (Story 6.14).
