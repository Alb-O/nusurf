{
  lib,
  pkgs,
  rustPlatform ? pkgs.rustPlatform,
}:

let
  cargoManifest = builtins.readFile ../Cargo.toml;
  packageSrc = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.lock
      ../src
    ];
  };
in
rustPlatform.buildRustPackage {
  pname = "nu_plugin_nusurf";
  version = "1.0.6";

  src = packageSrc;
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

  postPatch = ''
    printf '%s' ${lib.escapeShellArg cargoManifest} > Cargo.toml
  '';

  postInstall = ''
    mkdir -p $out/share/nushell/nusurf
    cp -r ${../nu} $out/share/nushell/nusurf/nu
    cp -r ${../schema} $out/share/nushell/nusurf/schema
  '';

  passthru = {
    nushellModulePath = "$out/share/nushell/nusurf/nu/cdp.nu";
  };

  meta = {
    description = "Nushell websocket plugin plus CDP module";
    homepage = "https://github.com/Alb-O/nusurf";
    license = lib.licenses.mit;
    mainProgram = "nu_plugin_nusurf";
    platforms = lib.platforms.linux;
  };
}
