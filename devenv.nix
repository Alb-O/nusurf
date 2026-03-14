{
  pkgs,
  config,
  lib,
  ...
}:

let
  standaloneProjectRoot = toString ./.;
  nuPluginWs = pkgs.rustPlatform.buildRustPackage {
    pname = config.rustEnv.package.name;
    version = config.rustEnv.package.version;
    src = config.outputs.cargo_source_tree;
    cargoLock.lockFile = ./Cargo.lock;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.openssl ];
    doCheck = false;
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
      ${standaloneProjectRoot}/scripts/update-cdp-schema.sh
    '';

    check-targets.exec = lib.mkForce ''
      cargo check --workspace --all-targets --all-features
    '';
  };

  outputs.nu-plugin-ws = nuPluginWs;

  enterShell = ''
    echo "Run: show-cargo-manifest"
    echo "Run: cargo-check"
    echo "Run: cargo-build"
  '';

  enterTest = ''
    set -euo pipefail

    rustc --version | grep -E "nightly|dev"
    cargo check --all-targets --all-features
    cargo test --all-targets --all-features
    cargo build
  '';
}
