{
  lib,
  pkgs,
  managedCargoDir ? null,
  cargoCatalogPath ? null,
  nuSessionPackage ? null,
  nuSessionSource ? null,
}:

let
  coercePath =
    pathLike:
    let
      valueType = builtins.typeOf pathLike;
    in
    if valueType == "path" then
      pathLike
    else if valueType == "set" && pathLike ? outPath then
      coercePath pathLike.outPath
    else if valueType == "string" && lib.hasPrefix builtins.storeDir pathLike then
      /. + builtins.unsafeDiscardStringContext (lib.removePrefix "/" pathLike)
    else if valueType == "string" && lib.hasPrefix "/" pathLike then
      /. + lib.removePrefix "/" pathLike
    else
      throw "nusurf packaging expected an absolute path for nuSessionSource";
  resolvedManagedCargoDir =
    if managedCargoDir != null then
      managedCargoDir
    else
      throw ''
        nusurf packaging requires ar_devenv_rust/modules/managed-cargo.
        Pass `managedCargoDir` to `nix/package.nix`.
      '';
  resolvedCargoCatalogPath =
    if cargoCatalogPath != null then
      cargoCatalogPath
    else
      "${resolvedManagedCargoDir}/Cargo.catalog.toml";
  resolvedNuSessionSource =
    if nuSessionSource != null then coercePath nuSessionSource else ../../nu_session;
  resolvedNuSessionPackage =
    if nuSessionPackage != null then
      nuSessionPackage
    else
      pkgs.callPackage (resolvedNuSessionSource + /nix/package.nix) {
        managedCargoDir = resolvedManagedCargoDir;
        cargoCatalogPath = resolvedCargoCatalogPath;
        sourceRoot = resolvedNuSessionSource;
      };
in
pkgs.runCommand "nusurf-1.0.6" { } ''
  mkdir -p "$out/bin" "$out/share/nushell/nusurf"
  ln -s ${resolvedNuSessionPackage}/bin/nu_plugin_nusurf "$out/bin/nu_plugin_nusurf"
  ln -s ${resolvedNuSessionPackage}/bin/nusurf_live_fixture_server "$out/bin/nusurf_live_fixture_server"
  cp -r ${../nu} "$out/share/nushell/nusurf/nu"
  cp -r ${../schema} "$out/share/nushell/nusurf/schema"
''
// {
  version = "1.0.6";
  passthru = {
    nushellModuleSubpath = "share/nushell/nusurf/nu/cdp";
  };

  meta = {
    description = "Nusurf Nu assets bundled with the nu_session-built websocket and CDP plugin";
    homepage = "https://github.com/Alb-O/nusurf";
    license = lib.licenses.mit;
    mainProgram = "nu_plugin_nusurf";
    platforms = lib.platforms.linux;
  };
}
