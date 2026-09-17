# decimal

An arbitrary-precision decimal library implemented in Lean 4, with formalized
semantics and kernel-checked proofs. For performance, compiled operations call
libmpdec through FFI, using the same library as Python's `decimal`.

## Usage

To use `decimal` as a dependency of another Lean project, prepare libmpdec on
your machine **before running `lake update` or `lake build` in that project**.
Then specify its installation location through environment variables or the
`decimal` dependency's `with` options, as shown below. Lake builds `decimal` along
with your project.

- The Lean version specified in `lean-toolchain`.
- **64-bit libmpdec >= 2.5.0**, including headers and a linkable library.
  Obtain the source from the [mpdecimal project](https://www.bytereef.org/mpdecimal/download.html)
  and install it yourself. The instructions below use mpdecimal 4.0.1.
- A C11 compiler with GCC/Clang-compatible command-line options and system C
  headers. The default is `cc` on Unix and `clang` on Windows.

The Lake build **never downloads, builds, or installs libmpdec**. A missing or
incompatible installation stops the build with an error.

### Prepare libmpdec

Download and extract the mpdecimal source archive yourself before running these
commands. You can transfer the archive from another machine for an offline
installation; the commands below do not fetch it. Use a prefix without spaces
while building the upstream library. Lake configuration accepts paths with spaces.

#### Linux

Install your distribution's C development tools, including a compiler and GNU
Make. Some distributions do not provide `libmpdec-dev`; a source install works
independently of that package name.

From the extracted mpdecimal source directory:

```bash
./configure --prefix="$HOME/.local/mpdecimal" --disable-cxx --enable-static --disable-shared CFLAGS="-O3 -fPIC"
make -j2
make install
```

Then add this dependency declaration to **your project's** `lakefile.lean`:

```lean
require decimal from git "https://github.com/Qiu233/decimal" with
  NameMap.empty.insert `mpdecPrefix "/home/alice/.local/mpdecimal"
```

Replace `/home/alice` with your actual home directory. Lean string literals do
not expand `$HOME` or `~`. A complete `lakefile.lean` example appears below.

#### macOS: Apple Silicon and Intel

Install Apple's Command Line Tools with `xcode-select --install` if necessary.
Use a Lean toolchain, compiler, and libmpdec built for the same architecture. On
Apple Silicon, use a native ARM64 terminal for the ARM64 toolchain; an x86-64
installation under Rosetta is a separate configuration.

From the extracted mpdecimal source directory:

```bash
./configure --prefix="$HOME/.local/mpdecimal" --disable-cxx --enable-static --disable-shared CC=clang CFLAGS="-O3 -fPIC"
make -j2
make install
```

Then add this dependency declaration to **your project's** `lakefile.lean`:

```lean
require decimal from git "https://github.com/Qiu233/decimal" with
  NameMap.empty
    |>.insert `mpdecPrefix "/Users/alice/.local/mpdecimal"
    |>.insert `mpdecCC "clang"
```

Replace `/Users/alice` with your actual home directory.

#### Windows x86-64

Use the native Windows Lean toolchain and **MSYS2 CLANG64**, matching
[Lean's Windows toolchain guidance](https://github.com/leanprover/lean4/blob/v4.34.0/doc/make/msys2.md).
An MSVC-targeting `clang.exe` or `clang-cl.exe` is not interchangeable with the
CLANG64 compiler. Do not mix 32-bit libraries, MSYS/Cygwin runtime libraries, or
unverified MSVC-built libraries with this configuration.

Install [MSYS2](https://www.msys2.org/) and open its **CLANG64** terminal. Install
the build tools explicitly:

```text
pacman -S --needed make mingw-w64-clang-x86_64-clang
```

In that terminal, from the extracted mpdecimal source directory, build a native
Windows static library:

```bash
./configure --prefix=/c/mpdecimal --disable-cxx --enable-static --disable-shared CC=clang CFLAGS="-O3"
make -j2
make install
```

Make the native compiler available to the PowerShell session and editor you use
for **your Lean project**. Adjust the paths if MSYS2 is installed elsewhere:

```powershell
$env:PATH = "C:\msys64\clang64\bin;$env:PATH"
```

In your project's `lakefile.lean`, configure the dependency:

```lean
require decimal from git "https://github.com/Qiu233/decimal" with
  NameMap.empty
    |>.insert `mpdecPrefix "C:/mpdecimal"
    |>.insert `mpdecCC "C:/msys64/clang64/bin/clang.exe"
```

Static linking means executables and `#eval` do not require a libmpdec DLL.
Restart the editor after changing its inherited environment.

### Environment variables

You can keep machine-specific paths out of your project's `lakefile.lean` by
using environment variables. The dependency declaration then needs no `with`:

```lean
require decimal from git "https://github.com/Qiu233/decimal"
```

On Linux or macOS, after installing libmpdec as above:

```bash
export MPDEC_PREFIX="$HOME/.local/mpdecimal"
export MPDEC_CC=clang  # Optional; Unix defaults to cc.
lake -R build
```

On Windows, in PowerShell:

```powershell
$env:PATH = "C:\msys64\clang64\bin;$env:PATH"
$env:MPDEC_PREFIX = "C:/mpdecimal"
$env:MPDEC_CC = "C:/msys64/clang64/bin/clang.exe"
lake -R build
```

Set these variables before running `lake update` or `lake build`. They are also
read when `decimal` is a transitive dependency. Start or restart your editor from
an environment containing the same settings.

Lake caches the resolved configuration. **After changing or unsetting any of
these variables, run `lake -R build`** in your project to reload it. An ordinary
`lake build` reuses the cached settings.

### Configuration options

If headers and libraries are on the compiler's default search paths, no location
settings are needed. Otherwise, use these keys in the dependency's `NameMap` or
the corresponding environment variables:

| Option | Environment variable | Meaning |
| --- | --- | --- |
| `mpdecPrefix` | `MPDEC_PREFIX` | Installation prefix containing `include/` and `lib/` |
| `mpdecIncludeDir` | `MPDEC_INCLUDE_DIR` | Override the header directory |
| `mpdecLibDir` | `MPDEC_LIB_DIR` | Override the library directory |
| `mpdecLibName` | `MPDEC_LIB_NAME` | Linker library name, default `mpdec` |
| `mpdecLinkFile` | `MPDEC_LINK_FILE` | Absolute path to a library or Windows import library |
| `mpdecCC` | `MPDEC_CC` | Host C compiler executable |

For each option, an explicit Lake setting takes precedence over its environment
variable, followed by the default. Empty environment values are ignored. Header
and library directories default to `include/` and `lib/` under the resolved
prefix; explicit directory settings override those defaults.

The consuming project's `-K` options do not automatically apply to its
dependencies: use `require ... with` or environment variables for dependencies.
Use absolute paths; spaces in paths are supported. Native link inputs propagate
to your project's executables automatically.

The instructions above use **static libmpdec**. On Unix,
`-fPIC` is needed for Lean's precompiled modules and `#eval`. If both static and
shared libraries are installed, set `mpdecLinkFile` or `MPDEC_LINK_FILE` to the
absolute path of `libmpdec.a` to ensure every link step selects the static library.
Static builds do not need a libmpdec runtime search path.

Source builds can also link a separately installed shared libmpdec. In that case,
make its shared library available to the runtime loader: `LD_LIBRARY_PATH` on
Linux, `DYLD_LIBRARY_PATH` on macOS, or `PATH` on Windows. This also applies to
`#eval` and the editor process.

### Add the dependency

After preparing libmpdec, the consuming project's `lakefile.lean` can start with:

```lean
module

public import Lake
public meta import Lake
open Lake DSL
public section

package myProject

require decimal from git "https://github.com/Qiu233/decimal" with
  NameMap.empty.insert `mpdecPrefix "/absolute/path/to/mpdecimal"
```

Use the `with` settings for your platform from the previous section and keep
your own project's targets below the dependency declaration. If using environment
variables, omit `with` and its `NameMap` instead. Use the Lean version specified in
this repository's `lean-toolchain`.

Run these commands from **your consuming project's root directory**:

```text
lake update
lake build
```

You can then `import Decimal` in your Lean files. After changing the dependency's
installation settings, run `lake -R build` to reload the configuration. If the
header, library, or compiler is missing or incompatible, Lake reports the
dependency error before compiling the library.

Keep the libmpdec headers and library installed: Lake checks them when configuring
the dependency and needs them when linking executables or rebuilding modules.

### Examples

The API supports exact construction from strings, integers, or coefficient/exponent
pairs; formatting; addition, subtraction, multiplication, division, quantize, and
context rounding. Signed zero, Infinity, NaN/sNaN payloads, all eight rounding
modes, and traps are supported. Floating-point conversion, Unicode digits, sqrt,
exp, ln, and fma are not yet implemented.

```lean
module

import Decimal
meta import Decimal  -- Needed for #eval; optional for runtime code and proofs.

def sum : Except Decimal.Flags Decimal := do
  let a ← Decimal.fromString "1.30"
  let b ← Decimal.fromString "1.20"
  let ctx : Decimal.Context := { precision := 28 }
  (Decimal.add ctx a b).check ctx

#eval sum  -- Except.ok "2.50"

#eval Decimal.div { precision := 6 }
  (Decimal.ofInt 1).value (Decimal.ofInt 7).value
-- { value := "0.142857", flags := 96 }   -- Inexact | Rounded
```

Run `lake lean Example.lean` from your consuming project to load the FFI and
precompiled modules. `meta import Decimal` makes code available for
compile-time execution and can coexist with the regular import. Running `lean`
alone does not automatically load this package's native symbols.

Construction is exact and independent of context precision. Arithmetic uses an
explicit immutable `Context`: the defaults are precision 28, half-even rounding,
Emin=-999999, and Emax=999999. Operations return `Result Decimal`, containing the
value and signals raised by that operation. `.check ctx` applies traps; the
default traps are InvalidOperation, DivisionByZero, and Overflow.
`.record ctx previousFlags` also accumulates sticky flags, even when a trap fires.
There is no implicit global context or arithmetic operator instance that silently
discards flags.

`==` is numerical equality: `1.0 == 1.00` and `-0 == 0`, while every NaN compares
unequal to itself. `sameRepresentation` distinguishes signs, coefficients,
exponents, and special values; propositional equality also uses representation
semantics. Use the public FFI API or `toModel`, rather than writing runtime
operations that assume the logical constructor's memory layout.

Precision is variable and coefficients use multiple machine words; available
memory is the practical limit. The supported 64-bit backend has a maximum
precision/adjusted exponent of 999999999999999999 and a minimum stored exponent of
-1999999999999999997. Out-of-range construction and invalid contexts signal
InvalidOperation. Bounds are checked before converting Lean integers to C integers.

## Formalized semantics

The public API provides Lean definitions and specification theorems for reasoning
about decimal operations through `Decimal.Model`. Kernel-checked proofs cover
rounding bounds, exact rounding, finite multiplication commutativity, and concrete
arithmetic.

`@[extern]` **does not prove the C implementation correct**. The theorems establish
properties of the logical model; libmpdec, the FFI bridge, compiler, and runtime
remain part of the execution trust boundary. Rounded addition is not
unconditionally associative, so Decimal is not an exact rational field. `toRat?`
provides a rational interpretation of finite values for specifications and proofs,
not for arithmetic with very large exponents.

Downstream Lean files should begin with `module` and `import Decimal` to access
the API and theorems. Use the public specification theorems to reason about
operations. For example, this transfers both value and flags to the model:

```lean
example (ctx : Decimal.Context) (a b : Decimal) :
    (Decimal.add ctx a b).map Decimal.toModel =
      Decimal.Model.add ctx a.toModel b.toModel := by
  simp
```
