{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.nusurf;
in
{
  options.programs.nusurf = {
    enable = lib.mkEnableOption "nusurf Nushell plugin and CDP module";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./nix/package.nix { }";
      description = ''
        Nusurf package to register as a Nushell plugin.
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
    programs.nushell = {
      enable = lib.mkDefault true;
      package = lib.mkDefault pkgs.nushell;
      plugins = [ cfg.package ];
      extraConfig = lib.mkIf cfg.importCdpModule (
        lib.mkAfter ''
          use ${cfg.package}/share/nushell/nusurf/nu/cdp.nu *
        ''
      );
    };
  };
}
