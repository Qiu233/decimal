module

public import Lake
public meta import Lake
open Lake DSL

private def mpdecPrefix : String := (get_config? mpdecPrefix).getD ""

private def mpdecIncludeDir : String := (get_config? mpdecIncludeDir).getD
  (if mpdecPrefix.isEmpty then "" else (System.FilePath.mk mpdecPrefix / "include").toString)

private def mpdecLibDir : String := (get_config? mpdecLibDir).getD
  (if mpdecPrefix.isEmpty then "" else (System.FilePath.mk mpdecPrefix / "lib").toString)

private def mpdecLibName : String := (get_config? mpdecLibName).getD "mpdec"
private def mpdecLinkFile : String := (get_config? mpdecLinkFile).getD ""

-- External headers need the host C SDK, which Lean's minimal sysroot need not contain.
private def mpdecCC : String := (get_config? mpdecCC).getD
  (if System.Platform.isWindows then "clang" else "cc")

private def mpdecIncludeArgs : Array String :=
  if mpdecIncludeDir.isEmpty then #[] else #["-I", mpdecIncludeDir]

private def mpdecLinkArgs : Array String :=
  (if mpdecLibDir.isEmpty then #[] else #["-L", mpdecLibDir] ++
    (if System.Platform.isWindows then #[] else #["-Wl,-rpath," ++ mpdecLibDir])) ++
  (if mpdecLinkFile.isEmpty then #["-l" ++ mpdecLibName] else #[mpdecLinkFile]) ++
  (if System.Platform.isWindows then #[] else #["-lm"])

private def runMpdecCC (args : Array String) : IO IO.Process.Output := do
  try
    IO.Process.output { cmd := mpdecCC, args }
  catch e =>
    throw <| IO.userError s!"decimal: cannot start C compiler '{mpdecCC}'. Install a C SDK or set -KmpdecCC=/path/to/compiler.\n{e}"

/-- Resolve the installed library to a real file so Lake can propagate it to
    downstream executables and track changes. No files are installed or copied. -/
private def findMpdecLibrary : IO System.FilePath := do
  if !mpdecLinkFile.isEmpty then
    let path := System.FilePath.mk mpdecLinkFile
    if ← path.pathExists then return path
    throw (IO.userError s!"decimal: mpdecLinkFile does not exist: {path}")
  let names := if System.Platform.isWindows then
      #[mpdecLibName ++ ".lib", "lib" ++ mpdecLibName ++ ".a", "lib" ++ mpdecLibName ++ ".dll.a"]
    else #["lib" ++ mpdecLibName ++ ".a", "lib" ++ mpdecLibName ++
      (if System.Platform.isOSX then ".dylib" else ".so")]
  for name in names do
    if !mpdecLibDir.isEmpty then
      let path := System.FilePath.mk mpdecLibDir / name
      if ← path.pathExists then return path
    let r ← runMpdecCC <| (if mpdecLibDir.isEmpty then #[] else #["-L", mpdecLibDir]) ++
      #["-print-file-name=" ++ name]
    if r.exitCode == 0 && r.stdout.trimAscii.copy != name then
      let path := System.FilePath.mk r.stdout.trimAscii.copy
      if ← path.pathExists then return path
  throw <| IO.userError "decimal: cannot locate the installed libmpdec file. Set -KmpdecLinkFile=/absolute/path/to/library (or mpdecLibDir)."

private def checkMpdec : IO Unit := IO.FS.withTempDir fun dir => do
  let src := dir / "probe.c"
  let exe := dir / (if System.Platform.isWindows then "probe.exe" else "probe")
  IO.FS.writeFile src "#include <mpdecimal.h>\n\
    #if !defined(MPD_CONFIG_64)\n\
    #error decimal requires a 64-bit libmpdec\n\
    #endif\n\
    #if MPD_VERSION_HEX < 0x02050000\n\
    #error decimal requires libmpdec >= 2.5.0\n\
    #endif\n\
    int main(void) {\n\
      uint32_t status = 0; mpd_t *x = mpd_qnew();\n\
      if (!x) return 1;\n\
      mpd_qset_string_exact(x, \"1.25\", &status);\n\
      mpd_del(x); return status != 0;\n\
    }\n"
  let r ← runMpdecCC <| mpdecIncludeArgs ++ #[src.toString] ++ mpdecLinkArgs ++
    #["-o", exe.toString]
  unless r.exitCode == 0 do
    throw <| IO.userError <|
      "decimal: usable libmpdec headers and library were not found.\n" ++
      "Required: libmpdec >= 2.5.0, configured for 64-bit arithmetic.\n" ++
      "Install it from https://www.bytereef.org/mpdecimal/download.html\n" ++
      "Custom prefix: lake -R -KmpdecPrefix=/absolute/prefix build\n" ++
      "Or configure mpdecIncludeDir, mpdecLibDir, mpdecLibName and mpdecCC separately.\n" ++
      "This build never downloads, builds or installs libmpdec.\n" ++ r.stderr

-- Fail while elaborating the package configuration, before compiling Lean modules.
private def mpdecChecked : Unit := run_io do
  checkMpdec
  discard findMpdecLibrary

-- Lake resolves its generated package declaration by its public name.
public section

package decimal where
  version := v!"0.1.0"
  requiresModuleSystem := true
  moreLinkArgs := mpdecLinkArgs
  moreLinkObjs := #[
    ⟨.facet (.packageTarget .anonymous `decimal_native) `static⟩,
    ⟨.packageTarget .anonymous `mpdecSystemLibrary⟩]

end

target mpdecSystemLibrary : System.FilePath := do
  inputBinFile (← findMpdecLibrary)

extern_lib decimal_native pkg := do
  let lean ← getLeanInstall
  -- Repeat the probe when using a cached lakefile as well.
  checkMpdec
  let src ← inputTextFile (pkg.dir / "native/decimal.c")
  let obj ← buildO (pkg.buildDir / "native/decimal.o") src #["-I", lean.includeDir.toString]
    (#["-std=c11", "-O3", "-Wall", "-Wextra", "-Werror"] ++
      (if System.Platform.isWindows then #[] else #["-fPIC"]) ++ mpdecIncludeArgs)
    mpdecCC (do addLeanTrace; addPureTrace mpdecCC; pure .nil)
  buildStaticLib (pkg.staticLibDir / nameToStaticLib "decimal_native") #[obj]

lean_lib Decimal where
  precompileModules := true

@[default_target] lean_exe decimal where
  root := `Main

@[test_driver] lean_exe decimalTests where
  root := `Tests.Main

lean_exe decimalOracle where
  root := `Tests.Oracle

lean_exe decimalBench where
  root := `Bench
