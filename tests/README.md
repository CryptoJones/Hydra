# Hydra Test Suite

```bash
# Install the test runner (one of):
sudo apt install bats          # Debian / Ubuntu
sudo dnf install bats          # Fedora / RHEL
sudo pacman -S bats            # Arch
# Or grab from source: https://github.com/bats-core/bats-core

# Run the whole suite
bats tests/

# Filter by name
bats tests/ -f "usb"

# Verbose output
bats tests/ --print-output-on-failure --verbose-run
```

`./hydra.sh deps` installs `bats` alongside the other dependencies, so if
you've already bootstrapped the project the runner is already present.

## What's covered

**CLI-level** (exercise `hydra.sh` as a subprocess):
- `help` prints usage and exits 0
- Unknown subcommands fail with a useful message
- No-argument default falls through to `check`
- `usb`, `copy`, `test` all error cleanly when their device argument is missing
- `usb` refuses non-existent paths and regular files (not block devices)

**Function-level** (source `hydra.sh`, call internal functions):
- URL constants substitute `HYDRA_*_VERSION` env overrides correctly
- `ventoy_installer_path` errors when the Ventoy archive hasn't been extracted
- `ventoy_installer_path` returns the script path when present
- `validate_usb_device` rejects empty args and non-block files

**Invariants** (script structure regressions):
- `hydra.sh` parses as valid bash (`bash -n`)
- Starts with shebang + SPDX header
- Has the `BASH_SOURCE` guard that makes sourcing safe for tests

## Conventions

- **No host writes.** Every test uses `BATS_TEST_TMPDIR` or `mktemp` for any
  file or directory it creates, and `teardown()` cleans up.
- **No sudo.** Tests that would otherwise need real block devices are scoped
  to the argument-validation path (file-doesn't-exist, file-is-regular).
  We deliberately do not test the actual Ventoy write path — that requires
  a real USB and is verified by `./hydra.sh test /dev/sdX` end-to-end.
- **Sourcing safety.** Function-level tests rely on the `BASH_SOURCE[0] ==
  ${0}` guard at the bottom of `hydra.sh`. If you remove or break that
  guard, every function-level test starts running `main()` instead and the
  whole suite breaks loudly.

## Adding tests for a new function

1. Add a `@test "..."` block to `tests/hydra.bats`.
2. If you need to call an internal function, start the body with
   `source "$HYDRA"`. Combine with env overrides: `HYDRA_FOO=bar source "$HYDRA"`.
3. If your function shells out to `lsblk` / `sudo` / `findmnt`, drop a
   matching stub script into `$STUB_DIR` (already prepended to `PATH` by
   `setup()`) before running the function.
