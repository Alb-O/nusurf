{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  standaloneProjectRoot = toString ./.;
  nusurf = pkgs.callPackage ./nix/package.nix {
    managedCargoDir = "${inputs.ar_devenv_rust}/modules/managed-cargo";
    nuSessionSource = inputs.nu_session;
  };
in
{
  imports = [ ./nushell-plugin/devenv.nix ];

  rustEnv.managedCargo = {
    enable = false;
  };

  composer.ownInstructions =
    let
      currentProject = baseNameOf (toString ./.);
    in
    lib.optionalAttrs (builtins.pathExists ./AGENTS.md) {
      "${currentProject}" = [ (builtins.readFile ./AGENTS.md) ];
    };

  scripts.update-cdp-schema.exec = ''
    nu ${standaloneProjectRoot}/scripts/update-cdp-schema.nu
  '';

  outputs.nusurf = nusurf;

  enterShell = ''
    echo "Run: nu-with-nusurf"
    echo "Plugin: $NUSURF_PLUGIN"
  '';

  enterTest = ''
    set -euo pipefail

    test -x "$NUSURF_PLUGIN"
    test -x "$NUSURF_FIXTURE_BINARY"
    ./tests/run_suite mock_all
  '';
}
