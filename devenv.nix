{
  pkgs,
  config,
  lib,
  inputs,
  ...
}:

let
  standaloneProjectRoot = toString ./.;
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
      throw "nusurf devenv expected an absolute path for inputs.nu_session";
  resolvedNuSessionSource =
    if inputs ? nu_session then coercePath inputs.nu_session else ../nu_session;
  nuSessionSource = lib.fileset.toSource {
    root = resolvedNuSessionSource;
    fileset = lib.fileset.unions [
      (resolvedNuSessionSource + /Cargo.toml)
      (resolvedNuSessionSource + /Cargo.poly.toml)
      (resolvedNuSessionSource + /crates)
    ];
  };
  compositeSource = pkgs.runCommand "nusurf-devenv-source-tree" { } ''
    mkdir -p "$out/source/nusurf" "$out/source/nu_session"
    cp -r ${config.outputs.cargo_source_tree}/. "$out/source/nusurf/"
    cp -r ${nuSessionSource}/. "$out/source/nu_session/"
    chmod -R u+w "$out/source/nusurf" "$out/source/nu_session"
  '';
  nusurf = pkgs.rustPlatform.buildRustPackage {
    pname = config.rustEnv.package.name;
    version = config.rustEnv.package.version;
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
    doCheck = false;
    postPatch = ''
      cp nusurf/Cargo.lock "$cargoDepsCopy/Cargo.lock"
    '';
  };
in
{
  rustEnv.managedCargo = {
    enable = true;
    specPath = "${standaloneProjectRoot}/Cargo.poly.toml";
  };

  composer.ownInstructions =
    let
      currentProject = baseNameOf (toString ./.);
    in
    lib.optionalAttrs (builtins.pathExists ./AGENTS.md) {
      "${currentProject}" = [ (builtins.readFile ./AGENTS.md) ];
    };

  scripts = {
    base-toolchain.exec = ''
      rustc --version
      cargo --version
    '';

    show-cargo-manifest.exec = ''
      cat ${config.outputs.cargo_manifest}
    '';

    cargo-check.exec = ''
      cargo check --all-targets --all-features
    '';

    cargo-build.exec = ''
      cargo build
    '';

    update-cdp-schema.exec = ''
      nu ${standaloneProjectRoot}/scripts/update-cdp-schema.nu
    '';

    check-targets.exec = lib.mkForce ''
      cargo check --workspace --all-targets --all-features
    '';
  };

  outputs.nusurf = nusurf;

  enterShell = ''
    echo "Run: show-cargo-manifest"
    echo "Run: cargo-check"
    echo "Run: cargo-build"
    echo "Run: nu-with-nusurf"
  '';

  enterTest = ''
    set -euo pipefail

    rustc --version | grep -E "nightly|dev"
    cargo check --all-targets --all-features
    cargo test --all-targets --all-features
    cargo build
  '';
}
