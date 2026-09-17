module

public import Lake
public meta import Lake
open Lake DSL

-- Explicit Lake options override environment variables; empty environment values
-- use the defaults. Lake caches run_io results, so changes require lake -R.
private def mpdecSetting (config : Option String) (envName fallback : String) : IO String := do
  if let some value := config then return value
  return ((← IO.getEnv envName).filter (! ·.isEmpty)).getD fallback

private def mpdecPrefix : String := run_io
  mpdecSetting (get_config? mpdecPrefix) "MPDEC_PREFIX" ""

private def mpdecIncludeDir : String := run_io
  mpdecSetting (get_config? mpdecIncludeDir) "MPDEC_INCLUDE_DIR"
    (if mpdecPrefix.isEmpty then "" else (System.FilePath.mk mpdecPrefix / "include").toString)

private def mpdecLibDir : String := run_io
  mpdecSetting (get_config? mpdecLibDir) "MPDEC_LIB_DIR"
    (if mpdecPrefix.isEmpty then "" else (System.FilePath.mk mpdecPrefix / "lib").toString)

private def mpdecLibName : String := run_io
  mpdecSetting (get_config? mpdecLibName) "MPDEC_LIB_NAME" "mpdec"
private def mpdecLinkFile : String := run_io
  mpdecSetting (get_config? mpdecLinkFile) "MPDEC_LINK_FILE" ""

-- External headers need the host C SDK, which Lean's minimal sysroot need not contain.
private def mpdecCC : String := run_io
  mpdecSetting (get_config? mpdecCC) "MPDEC_CC"
    (if System.Platform.isWindows then "clang" else "cc")

private def mpdecIncludeArgs : Array String :=
  if mpdecIncludeDir.isEmpty then #[] else #["-I", mpdecIncludeDir]

private def mpdecLinkArgs : Array String :=
  (if mpdecLibDir.isEmpty then #[] else #["-L", mpdecLibDir] ++
    (if System.Platform.isWindows then #[] else #["-Wl,-rpath," ++ mpdecLibDir])) ++
  (if mpdecLinkFile.isEmpty then #["-l" ++ mpdecLibName] else #[mpdecLinkFile]) ++
  -- macOS provides math symbols through libSystem; Lean's sysroot has no separate libm.
  (if System.Platform.isWindows || System.Platform.isOSX then #[] else #["-lm"])

private def runMpdecCC (args : Array String) : IO IO.Process.Output := do
  try
    IO.Process.output { cmd := mpdecCC, args }
  catch e =>
    throw <| IO.userError s!"decimal: cannot start C compiler '{mpdecCC}'. Install a C SDK or set MPDEC_CC (or -KmpdecCC) to the compiler path, then run lake -R build.\n{e}"

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
  throw <| IO.userError "decimal: cannot locate the installed libmpdec file. Set MPDEC_LINK_FILE (or mpdecLinkFile) to the absolute library path, then run lake -R build."

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
      "Set MPDEC_PREFIX to the installation prefix, then run lake -R build.\n" ++
      "Or set mpdecPrefix in require ... with (or -KmpdecPrefix for decimal itself).\n" ++
      "Headers, libraries and compiler can also be configured separately; see README.md.\n" ++
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
