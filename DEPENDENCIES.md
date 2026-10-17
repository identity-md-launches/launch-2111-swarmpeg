# Vendored dependencies

All dependency source and licence files are ordinary files under `lib/`.
No package install, git submodule, or network access is needed to build.

```text
OpenZeppelin/openzeppelin-contracts v5.1.0
Source: https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.1.0
Archive SHA-256: 8a3b08cfc756437ba3343901565b18182adb42ec1e621960240a19da5d738686
Vendored files: 6

foundry-rs/forge-std v1.9.7
Source: https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7
Archive SHA-256: 45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94
Vendored files: 30
```

OpenZeppelin is limited to the unmodified ERC-20 implementation and its import
closure. Forge Standard Library includes its unmodified Solidity sources and
both upstream licences; it is used only by tests.
