This directory vendors unmodified LLVM libc++ floating-point conversion sources
from the llvmorg-21.1.3 release. SOURCE.json records upstream URLs and SHA-256
hashes. LICENSE.TXT includes the Apache License 2.0 and LLVM exceptions; Ryu's
original notices are retained in the source files.

scripts/development/build-modern-runtime.sh selects the nine floating to_chars
overloads from src/charconv.cpp into a generated build file. Integer and
from_chars implementations are not compiled. No system libc++ is replaced.
The adapter supplies missing exports for the experimental macOS 27 GPU backend
on iPadOS 16.1. Runtime/device validation is required separately from compilation.
