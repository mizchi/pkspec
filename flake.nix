{
  description = "pkthunder — language-agnostic test runner that extends pkl test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pkthunder = pkgs.buildGoModule {
          pname = "pkthunder";
          version = "0.0.0";
          src = ./.;

          vendorHash = "sha256-0LEwWuRj2Oc66rNZ+Psr11hsESue/YXU2veoaWQpKw4=";

          subPackages = [ "cmd/pkt" ];

          ldflags = [ "-s" "-w" ];

          # `pkt` shells out to `pkl` (via pkl-go) for evaluation, and
          # `pkt run --reader-helper` re-invokes itself, so PATH needs both.
          # Wrapping ensures users who installed pkthunder via Nix get a
          # working `pkl` without a separate install step.
          nativeBuildInputs = [ pkgs.makeWrapper ];
          postInstall = ''
            wrapProgram $out/bin/pkt \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.pkl ]}
          '';

          meta = with pkgs.lib; {
            description = "Language-agnostic test runner that extends pkl test";
            homepage = "https://github.com/mizchi/pkthunder";
            license = licenses.mit;
            mainProgram = "pkt";
            platforms = platforms.unix;
          };
        };
      in {
        packages = {
          default = pkthunder;
          pkthunder = pkthunder;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = pkthunder;
          name = "pkt";
        };

        # `nix develop` for working on pkthunder itself.
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            go
            pkl
            gopls
          ];
        };
      });
}
