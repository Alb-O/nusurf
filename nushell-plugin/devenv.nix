{
  inputs,
  lib,
  pkgs,
  ...
}:

let
  nusurfPackage = pkgs.callPackage ../nix/package.nix {
    managedCargoDir = "${inputs.poly-rust-env}/modules/managed-cargo";
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
