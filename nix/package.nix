{
  lib,
  pkgs,
  rustPlatform ? pkgs.rustPlatform,
  managedCargoDir ? null,
  cargoCatalogPath ? null,
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
        nusurf packaging requires ar_rust_env/modules/managed-cargo.
        Pass `managedCargoDir` to `nix/package.nix`.
        Shared/local-input consumers should source it from an explicit
        dependency such as `inputs.ar_rust_env`.
      '';
  resolvedCargoCatalogPath =
    if cargoCatalogPath != null then
      cargoCatalogPath
    else
      "${resolvedManagedCargoDir}/Cargo.catalog.toml";
  resolvedNuSessionSource =
    if nuSessionSource != null then coercePath nuSessionSource else ../../nu_session;
  packagedNuSessionSource = lib.fileset.toSource {
    root = resolvedNuSessionSource;
    fileset = lib.fileset.unions [
      (resolvedNuSessionSource + /Cargo.toml)
      (resolvedNuSessionSource + /Cargo.poly.toml)
      (resolvedNuSessionSource + /crates)
    ];
  };
  packageFiles = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.lock
      ../Cargo.poly.toml
      ../README.md
      ../src
    ];
  };
  managedCargoLib = import "${resolvedManagedCargoDir}/lib.nix" {
    inherit pkgs lib;
  };
  managedCargoOutputs = managedCargoLib.mkManagedCargoOutputs {
    catalogPath = resolvedCargoCatalogPath;
    specPath = ../Cargo.poly.toml;
    sourcePath = packageFiles;
    derivationNamePrefix = "nusurf";
  };
  compositeSource = pkgs.runCommand "nusurf-source-tree" { } ''
    mkdir -p "$out/source/nusurf" "$out/source/nu_session"
    cp -r ${managedCargoOutputs.cargoSourceTree}/. "$out/source/nusurf/"
    cp -r ${packagedNuSessionSource}/. "$out/source/nu_session/"
    chmod -R u+w "$out/source/nusurf" "$out/source/nu_session"
  '';
in
rustPlatform.buildRustPackage {
  pname = "nu_plugin_nusurf";
  version = "1.0.6";

  src = compositeSource;
  unpackPhase = ''
    runHook preUnpack
    cp -r "$src"/source/nusurf ./nusurf
    cp -r "$src"/source/nu_session ./nu_session
    chmod -R u+w nusurf nu_session
    runHook postUnpack
  '';
  cargoRoot = "nusurf";
  buildAndTestSubdir = "nusurf";
  cargoHash = "sha256-iqQOMl6fKTHs5whSkUdvmiBROFRoV+jwE7W4bkk5fxU=";

  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.openssl ];
  postPatch = ''
    cp nusurf/Cargo.lock "$cargoDepsCopy/Cargo.lock"
  '';

  cargoBuildFlags = [
    "--bin"
    "nu_plugin_nusurf"
  ];
  cargoInstallFlags = [
    "--bin"
    "nu_plugin_nusurf"
  ];

  doCheck = false;
  RUSTC_BOOTSTRAP = "1";
  RUSTFLAGS = lib.concatStringsSep " " [
    "-Zfmt-debug=none"
    "-Zlocation-detail=none"
  ];

  postInstall = ''
    mkdir -p $out/share/nushell/nusurf
    cp -r ${../nu} $out/share/nushell/nusurf/nu
    cp -r ${../schema} $out/share/nushell/nusurf/schema
  '';

  passthru = {
    nushellModuleSubpath = "share/nushell/nusurf/nu/cdp";
  };

  meta = {
    description = "Nushell websocket plugin plus CDP module";
    homepage = "https://github.com/Alb-O/nusurf";
    license = lib.licenses.mit;
    mainProgram = "nu_plugin_nusurf";
    platforms = lib.platforms.linux;
  };
}
