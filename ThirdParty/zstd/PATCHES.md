Zstandard v1.5.7 source from https://github.com/facebook/zstd/tree/v1.5.7 .

Build-only adaptation: lib/module.modulemap exports textual headers under the local CZstd target name. This avoids Clang implicitly importing a configuration-macro-dependent precompiled zstd.h while building Zstandard's own internal C sources. No codec implementation changes.
