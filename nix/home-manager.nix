{ self }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.pkspec;
  system = pkgs.stdenv.hostPlatform.system;
in
{
  options.programs.pkspec = {
    enable = lib.mkEnableOption "pkspec";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${system}.pkspec;
      defaultText = lib.literalExpression "pkspec.packages.\${pkgs.stdenv.hostPlatform.system}.pkspec";
      description = "The pkspec package to install.";
    };

    pklPackage = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${system}.pkl-native;
      defaultText = lib.literalExpression "pkspec.packages.\${pkgs.stdenv.hostPlatform.system}.pkl-native";
      description = "The Pkl CLI package to install alongside pkspec.";
    };

    installPkl = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to install the native Pkl CLI in addition to pkspec.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ] ++ lib.optional cfg.installPkl cfg.pklPackage;
  };
}
