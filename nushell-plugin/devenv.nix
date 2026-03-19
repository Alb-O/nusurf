{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  nusurfPackage = pkgs.callPackage ../nix/package.nix {
    managedCargoDir = "${inputs.ar_rust_env}/modules/managed-cargo";
    nuSessionSource = inputs.nu_session;
  };
in
{
  packages = [
    pkgs.nushell
    nusurfPackage
  ];

  env = {
    NUSURF_PLUGIN = lib.getExe nusurfPackage;
    NUSURF_NU_LIB_DIR = "${nusurfPackage}/share/nushell/nusurf/nu";
    NUSURF_CDP_MODULE = "${nusurfPackage}/share/nushell/nusurf/nu/cdp";
  };

  scripts.nu-with-nusurf.exec = ''
    nu --plugins "$NUSURF_PLUGIN" "$@"
  '';
}
