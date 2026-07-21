# Contributing to SwiftStockfish

Thank you for helping improve SwiftStockfish. Keep each pull request focused,
add or update tests for behavior changes, and describe any platform assumptions
that affect the binary and source build paths.

## Testing

Run the default offline suite before submitting a change:

```sh
swift test
```

The live-engine tests download the required NNUE networks and are opt-in:

```sh
SWIFTSTOCKFISH_INTEGRATION=1 swift test
```

Changes to the engine source, bridge, package manifest, or build scripts should
be checked on both an Apple host (the xcframework path) and Linux (the
from-source path) when possible. Do not add tests that contact the network to
the default suite; use the injected transport seam for hermetic loader tests.

## Stockfish updates and generated binaries

Use `Tools/update-stockfish.sh <tag>` to refresh the vendored engine and reapply
the patches in `Tools/patches/`. Keep `.upstream-version`, the network manifest,
patch documentation, and the rebuilt xcframework in sync. Review all vendored
source changes before committing them.

Do not hand-edit or submit an unexplained prebuilt engine. The corresponding
source, local patches, and `Tools/build-xcframework.sh` must reproduce every
distributed Stockfish binary.

## Licensing and repository hygiene

SwiftStockfish and contributions to it are distributed under GPL-3.0 because
the package ships and links Stockfish. Contributions must be original or
available under terms compatible with that license. Record the source, exact
revision, license, and purpose of any newly incorporated third-party material
in `THIRD_PARTY_NOTICES.md` and the relevant source documentation.

Do not commit credentials, tokens, session URLs, private network addresses,
hostnames, user-specific filesystem paths, NNUE downloads, or unrelated logs.
Inspect the staged diff before pushing; deleting sensitive data in a later
commit does not remove it from Git history.
