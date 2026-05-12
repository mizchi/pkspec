{
  description = "pkspec — language-agnostic test runner that extends pkl test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        version = "0.1.0";
        pkspec = pkgs.buildGoModule {
          pname = "pkspec";
          inherit version;
          src = ./.;

          vendorHash = "sha256-XE5jU3X1tDVPiPbq6/yHjDzlxKpi+U9LKEil7kk238I=";

          subPackages = [ "cmd/pkspec" ];

          ldflags = [
            "-s"
            "-w"
            "-X main.version=${version}"
          ];

          # `pkspec` shells out to `pkl` (via pkl-go) for evaluation, and
          # `pkspec run --reader-helper` re-invokes itself, so PATH needs both.
          # Wrapping ensures users who installed pkspec via Nix get a
          # working `pkl` without a separate install step.
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postInstall = ''
            wrapProgram $out/bin/pkspec \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.pkl ]}
          '';

          meta = with pkgs.lib; {
            description = "Language-agnostic test runner that extends pkl test";
            homepage = "https://github.com/mizchi/pkspec";
            license = licenses.mit;
            mainProgram = "pkspec";
            platforms = platforms.unix;
          };
        };
      in {
        packages = {
          default = pkspec;
          pkspec = pkspec;
        };

        apps.default = {
          type = "app";
          program = "${pkspec}/bin/pkspec";
          meta = pkspec.meta;
        };

        # `nix develop` for working on pkspec itself.
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            go
            pkl
            gopls
          ];
        };
      });
}
