{
  lib,
  pkgs,
  rustPlatform ? pkgs.rustPlatform,
  managedCargoDir ? null,
  cargoCatalogPath ? null,
}:

let
  resolvedManagedCargoDir =
    if managedCargoDir != null then
      managedCargoDir
    else
      throw ''
        nusurf packaging requires poly-rust-env/modules/managed-cargo.
        Pass `managedCargoDir` to `nix/package.nix`.
        Shared/local-input consumers should source it from an explicit
        dependency such as `inputs.poly-rust-env`.
      '';
  resolvedCargoCatalogPath =
    if cargoCatalogPath != null then
      cargoCatalogPath
    else
      "${resolvedManagedCargoDir}/Cargo.catalog.toml";
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
in
rustPlatform.buildRustPackage {
  pname = "nu_plugin_nusurf";
  version = "1.0.6";

  src = managedCargoOutputs.cargoSourceTree;
  cargoLock.lockFile = ../Cargo.lock;

  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.openssl ];

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
