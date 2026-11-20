# Upgrading the Ripple-patched Homebrew installation

On 20 November 2026 the tested installation was Homebrew oMLX **0.8.0** on an M5 Max with 128 GB of unified memory. It has two local changes: Ripple‑65B model loading and oQ calibration, and single-request DFlash2 decoding. Both survive restarting `omlx serve` or rebooting the Mac. The runtime loads the patches from the Homebrew installation and has no dependency on the test checkout in `/tmp`.

## Keep the tested build

To exclude oMLX from routine Homebrew upgrades, pin the formula. Check its installed version and pin status with:

```sh
brew pin omlx
brew list --versions omlx
brew list --pinned
```

An explicit `brew reinstall omlx` can replace the locally edited files even at the same version. The source for both changes is preserved on the fork’s [stacked Ripple DFlash2 branch](https://github.com/x746b/omlx/tree/feat/ripple-dflash2).

## Move to a newer release

1. Check whether the **specific release packaged by Homebrew** contains both [Ripple serving and oQ quantization (#5436)](https://github.com/jundot/omlx/pull/5436) and [Ripple DFlash2 decoding (#5437)](https://github.com/jundot/omlx/pull/5437). A merge into upstream main can precede a Homebrew release.
2. If either change is missing and you still need it, keep the current installation or port the missing change to the new version in a separate checkout and test it first. Copying entire Python files from 0.8.0 can overwrite newer loader or cache logic.
3. Once ready, stop the running server, run `brew unpin omlx` if pinned, then `brew upgrade omlx`. Restart with your usual `omlx serve` command.
4. Load the existing `ricursiveAI_Ripple-65B-Preview-oQ8e` and generate a short completion. Then enable DFlash on that target, select `ricursiveAI_Ripple-65B-Preview-DFlash2`, and send a single request. Look for `DFlash drafter attached to engine` at load and an `accept=…` count after generation. This checks that the speculative path actually ran.

The model weights and drafter live separately under `~/AI/models`. Replacing the Homebrew runtime requires neither a new download nor another BF16 → oQ8e conversion.
