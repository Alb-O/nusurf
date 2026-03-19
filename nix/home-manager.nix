{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.nusurf;
  resolvedPackage =
    if cfg.package != null then
      cfg.package
    else if cfg.managedCargoDir != null then
      pkgs.callPackage ./package.nix {
        managedCargoDir = cfg.managedCargoDir;
      }
    else
      null;
in
{
  options.programs.nusurf = {
    enable = lib.mkEnableOption "nusurf Nushell plugin and CDP module";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      defaultText = lib.literalExpression "null";
      description = ''
        Nusurf package to register as a Nushell plugin. When null, set
        `programs.nusurf.managedCargoDir` so the module can build the package.
      '';
    };

    managedCargoDir = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.oneOf [
          lib.types.path
          lib.types.str
        ]
      );
      default = null;
      description = ''
        Path to `ar_devenv_rust/modules/managed-cargo` used to build the bundled
        Nusurf package when `programs.nusurf.package` is not set.
      '';
    };

    importCdpModule = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Import the bundled `cdp` Nushell module into `config.nu`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = resolvedPackage != null;
        message = ''
          programs.nusurf.enable requires either programs.nusurf.package or
          programs.nusurf.managedCargoDir so the plugin package can be built
          without sibling-repo path assumptions.
        '';
      }
    ];

    programs.nushell = {
      enable = lib.mkDefault true;
      package = lib.mkDefault pkgs.nushell;
      plugins = [ resolvedPackage ];
      extraConfig = lib.mkIf cfg.importCdpModule (
        lib.mkAfter ''
          use ${resolvedPackage}/share/nushell/nusurf/nu/cdp
        ''
      );
    };
  };
}
