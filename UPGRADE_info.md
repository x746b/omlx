# Homebrew oMLX with this fork's pull requests

Updated 21 November 2026. Machine: M5 Max, 128 GB unified memory.

## Setup

| | Where | Managed by |
|---|---|---|
| oMLX runtime | Homebrew `omlx` (tap `jundot/omlx`, built `--with-grammar`: xgrammar + torch for constrained JSON/schema output), `/opt/homebrew/opt/omlx/libexec` | `brew upgrade` (keeps the install options) |
| Fork patches | applied on top of Homebrew's files by [`scripts/brew-apply-prs.sh`](scripts/brew-apply-prs.sh) | this repo |
| Development | `~/opt/omlx` (fork `x746b/omlx`, remote `upstream` = `jundot/omlx`) | git |
| Splash (GGUF engine) | Homebrew `splash` (tap `incoai/tap`) | `brew upgrade`, independent of oMLX |
| Settings, logs, models | `~/.omlx`, `~/AI/models` | untouched by all of the above |

Open pull requests applied to the runtime:

| PR | Patch | Branch | State (21 Nov 2026) |
|---|---|---|---|
| [#5436](https://github.com/jundot/omlx/pull/5436) | Ripple-65B Preview serving + oQ calibration | `feat/ripple-65b` | open |
| [#5437](https://github.com/jundot/omlx/pull/5437) | Ripple single-request DFlash2 (stacked on #5436) | `feat/ripple-dflash2` | draft |
| [#5455](https://github.com/jundot/omlx/pull/5455) | MiMo V2 SSD expert offload + Flash Lightning MTP | `feat/mimo-expert-offload` | open |

#5437 contains #5436's commit, so the script applies only #5437 for both.

## The patch script

```sh
scripts/brew-apply-prs.sh --check 5436 5437 5455   # test only, changes nothing
scripts/brew-apply-prs.sh 5436 5437 5455           # apply (server stopped)
scripts/brew-apply-prs.sh --status                 # what is applied; warns if an upgrade wiped it
scripts/brew-apply-prs.sh --revert                 # restore Homebrew's original files
```

What it does:

1. Finds Homebrew's oMLX (`brew --prefix omlx`) and its version.
2. Downloads each PR's metadata, commit list and diff from GitHub (`GITHUB_TOKEN` optional, for the API rate limit).
3. Skips a PR whose commits are all inside another listed PR (stacked branches).
4. Applies the diffs, in order, to a scratch copy of the `omlx` package. Only `omlx/*` paths; tests and docs are left out. A diff that is already present is skipped. If any diff fails, it stops and changes nothing.
5. Backs up every file it will touch to `libexec/.omlx-prs/backup`, copies the patched files in, clears `__pycache__`, and checks that `omlx.cli` still imports.
6. Records what it applied inside the Cellar (removed by an upgrade, together with the patched files) and in `~/.config/omlx-prs/last-applied` (kept), so `--status` can tell when an upgrade wiped the patches.

It needs only Homebrew oMLX, git, curl and macOS's stock bash; it uses Homebrew oMLX's own Python for JSON. Anyone with Homebrew oMLX can run it with their own PR numbers, or with `--repo` for another fork.

Verified on 21 Nov 2026 against v0.8.2: applying the GitHub diffs of #5437 and #5455 to stock v0.8.2 gives a tree byte-identical to `v0.8.2` + the 4 cherry-picked commits, on which the Ripple, DFlash, MoE offload, DeepSeek V4.1 offload, Inkling and Hy4 tests passed (262 passed, 9 skipped, 1 failed). The failure, `test_hy_v4.py::test_nax_paths_match_their_references`, fails the same on stock v0.8.2: it needs the optional custom Metal kernels, which the Homebrew build does not include. Hy4's indexer then uses the plain MLX path (slower, not broken).

## Upgrading oMLX

```sh
# 1. Stop the oMLX server.
cd ~/opt/omlx
brew update
brew info omlx | head -2                           # new stable version?
gh release list -R jundot/omlx -L 3                # release notes: did any of the PRs land?

# 2. Upgrade, keeping the old version's folder as a fallback.
brew unpin omlx
HOMEBREW_NO_INSTALL_CLEANUP=1 brew upgrade omlx
brew pin omlx

# 3. Re-apply.
scripts/brew-apply-prs.sh --check 5436 5437 5455
scripts/brew-apply-prs.sh 5436 5437 5455
scripts/brew-apply-prs.sh --status

# 4. Start the server as usual and run the checks below.
```

- A PR merged upstream and included in the release: the script reports "already in oMLX X" and skips it. Drop it from the command afterwards.
- A PR that no longer applies: the script stops with the failing hunks and nothing changes. Rebase that branch onto the release in `~/opt/omlx`, push it (the PR diff updates), and rerun. Until then, either run the new version without that PR, or go back to the previous version (below).
- `brew upgrade` (all formulas) and `brew reinstall omlx` also replace the patched files. `brew pin omlx` keeps the first from touching oMLX; after any reinstall, run `--status`.

### Going back to the previous version

With `HOMEBREW_NO_INSTALL_CLEANUP=1` the previous version's folder stays in the Cellar until `brew cleanup omlx`. Run it directly; its patches are still applied, since they live inside that folder:

```sh
ls /opt/homebrew/Cellar/omlx/
/opt/homebrew/Cellar/omlx/<old>/bin/omlx serve
```

Once the new version is verified: `brew cleanup omlx`.

Backup of the hand-patched 0.8.0 install (before the move to 0.8.2): `_backup_/brew-0.8.0-patched/` (`omlx/` package and the old Ripple variant `mlx_lm/models/ricursive.py`).

## Checks after patching

1. **Ripple + DFlash2.** Load `ricursiveAI_Ripple-65B-Preview-oQ8e`, generate a short completion. Enable DFlash, select `ricursiveAI_Ripple-65B-Preview-DFlash2`, send one request. Expect `DFlash drafter attached to engine` at load and an `accept=…` count after generation (`~/.omlx/logs/server.log`).
2. **MiMo offload + MTP.** Load `TensorFold_MiMo-V2.6-Flash-RL-MLX-4bit-MTP` with SSD expert offload and Lightning MTP on; generate a short completion.
3. **Inkling-2-Mini** (needs oMLX >= 0.8.1). Load `mlx-community_Inkling-2-Mini-oQ4e-mtp`: a text prompt, an image prompt, then with MTP on.
4. **Splash.** Load `orcarouter_Flint-abliterated-GGUF` and generate.
5. **Clients.** mycli against `http://127.0.0.1:8000/v1`; the admin dashboard opens.

If a model failed to load before a fix, click **Reload models** or restart oMLX (it caches load failures).

## Benchmarks

### Inkling-2-Mini oQ4e MTP (21 Nov 2026)

Model `mlx-community/Inkling-2-Mini-oQ4e-mtp` (16.8 GB; 26.4B total, 3.4B active, looped MoE). Homebrew oMLX 0.8.2 with #5437 and #5455 applied, M5 Max 128 GB. oMLX admin benchmark, engine Auto, context "Code (Python)".

Single request:

| Test | TTFT (ms) | TPOT (ms) | PP TPS | TG TPS | E2E (s) | Throughput | Peak MLX |
|---|---:|---:|---:|---:|---:|---:|---:|
| PP1024/TG128 | 659.5 | 17.99 | 1552.6 | 56.0 | 2.947 | 390.9 | 18.22 GB |
| PP4096/TG128 | 2268.4 | 15.13 | 1805.7 | 66.6 | 4.194 | 1007.1 | 20.41 GB |
| PP8192/TG128 | 4648.0 | 18.05 | 1762.5 | 55.9 | 6.944 | 1198.2 | 21.57 GB |
| PP16384/TG128 | 9516.3 | 17.50 | 1721.7 | 57.6 | 11.743 | 1406.1 | 23.61 GB |

Continuous batching, PP1024/TG128:

| Batch | TG TPS | Speedup | PP TPS | PP TPS/req | TTFT (ms) | E2E (s) |
|---|---:|---:|---:|---:|---:|---:|
| 1x | 56.0 | 1.00x | 1552.6 | 1552.6 | 659.5 | 2.947 |
| 2x | 64.9 | 1.16x | 1614.8 | 807.4 | 1243.3 | 5.164 |
| 4x | 97.4 | 1.74x | 1571.4 | 392.9 | 2486.3 | 7.763 |

Generation stays at 56–67 tok/s from 1K to 16K context, and peak memory grows only from 18 to 24 GB. The code context favours MTP drafting; plain chat may decode somewhat slower.

## Development

Work on the PR branches in `~/opt/omlx` as before. Run tests against a release with a temporary worktree:

```sh
git fetch upstream --tags
git worktree add --detach ../omlx-test v0.8.2
cd ../omlx-test && git cherry-pick d0121686 7c25ed2d 87442073 aa4ec6d4
PYTHONPATH=$PWD ~/opt/omlx/.venv/bin/python3 -m pytest -q tests/test_ripple.py tests/test_moe_offload_compat.py
cd ~/opt/omlx && git worktree remove ../omlx-test
```

`~/opt/omlx/.venv` is a dev venv that borrows Homebrew oMLX's packages through `omlx-lab-runtime.pth`; it follows whatever Homebrew has installed.

## Optional: custom kernels

The Homebrew formula has `--with-custom-kernel` (needs cmake and the Metal compiler: `xcrun metal --version` must succeed; neither is installed on 21 Nov 2026). It would speed up Hy4 / Hy4-flash (sparse-attention indexer, M5 tensor-unit paths). Not needed for anything above.
