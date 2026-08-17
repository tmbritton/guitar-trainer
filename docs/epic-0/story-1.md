# Epic 0 / Story 1 — Install Odin via mise

**Goal:** Odin toolchain installed and pinned for the project via mise, verified working.

**Why mise:** Odin is available in the mise registry as `github:odin-lang/Odin`. mise is already installed on this machine (`2026.7.18`). Pinning in a project `mise.toml` makes the toolchain reproducible.

## Deliverable

- `mise.toml` in the project root pinning an Odin version.
- `odin version` and `odin report` run successfully inside the project directory.

## Steps

- [ ] **Step 1: Install & pin Odin.** Run `mise use odin@latest` in the project root. This writes `[tools] odin = "latest"` (or a concrete version) to `mise.toml` and installs the toolchain.
- [ ] **Step 2: Verify the binary.** Run `mise exec -- odin version`. Expected: a version string (e.g. `dev-2026-xx`).
- [ ] **Step 3: Verify the toolchain report.** Run `mise exec -- odin report`. Expected: backend/LLVM info printed with no error — confirms the compiler backend is functional, not just the launcher.
- [ ] **Step 4: Confirm vendor collections are present.** Check that `$(mise where odin)/vendor/raylib` and `$(mise where odin)/vendor/miniaudio` exist. These ship with Odin and are the only audio/graphics deps we need.

## Verification

`mise exec -- odin version` prints a version and `vendor/raylib` + `vendor/miniaudio` directories exist under the Odin install root.

## Notes

- If `latest` resolves to a source build that needs LLVM, mise's Odin plugin handles the build; `odin report` failing on LLVM would surface here rather than deep in Epic 1.
- No system packages beyond what mise pulls; raylib/miniaudio are vendored.
