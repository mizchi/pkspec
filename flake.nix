{
  description = "pkspec — language-agnostic test runner that extends pkl test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    pkfire.url = "github:mizchi/pkfire/v0.9.0";
  };

  outputs = { self, nixpkgs, flake-utils, pkfire }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        version = "0.2.0";
        go_1_26_3 = pkgs.go_1_26.overrideAttrs (_old: {
          version = "1.26.3";
          src = pkgs.fetchurl {
            url = "https://go.dev/dl/go1.26.3.src.tar.gz";
            hash = "sha256-HGRoddCqh5kTMYTtV895/yS97+jIggRwYCqdPW2Rkrg=";
          };
        });
        buildGo1263Module = pkgs.buildGo126Module.override {
          go = go_1_26_3;
        };
        pklNative = pkgs.callPackage ./nix/pkl-native.nix { };
        pkspec = buildGo1263Module {
          pname = "pkspec";
          inherit version;
          src = ./.;

          vendorHash = "sha256-XE5jU3X1tDVPiPbq6/yHjDzlxKpi+U9LKEil7kk238I=";

          subPackages = [
            "cmd/pkspec"
            "cmd/pkspec-adapter-vitest"
            "cmd/pkspec-adapter-playwright"
            "cmd/pkspec-adapter-node-test"
            "cmd/pkspec-adapter-go-test"
            "cmd/pkspec-adapter-moon-test"
          ];

          ldflags = [
            "-s"
            "-w"
            "-X main.version=${version}"
          ];

          # `pkspec` shells out to `pkl` (via pkl-go) for evaluation, and
          # `pkspec run --reader-helper` re-invokes itself, so PATH needs both.
          # Wrapping ensures users who installed pkspec via Nix get a
          # working native `pkl` without a separate install step.
          nativeBuildInputs = [ pkgs.makeWrapper ];
          nativeCheckInputs = [ pklNative ];
          postInstall = ''
            for bin in $out/bin/pkspec*; do
              wrapProgram "$bin" \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pklNative ]}
            done
          '';

          meta = with pkgs.lib; {
            description = "Language-agnostic test runner that extends pkl test";
            homepage = "https://github.com/mizchi/pkspec";
            license = licenses.mit;
            mainProgram = "pkspec";
            platforms = platforms.unix;
          };
        };
        pklNativeClosure = pkgs.closureInfo {
          rootPaths = [ pklNative ];
        };
        pkspecClosure = pkgs.closureInfo {
          rootPaths = [ pkspec ];
        };
        homeManagerModuleEval = pkgs.lib.evalModules {
          specialArgs = { inherit pkgs; };
          modules = [
            {
              options.home.packages = pkgs.lib.mkOption {
                type = pkgs.lib.types.listOf pkgs.lib.types.package;
                default = [ ];
              };
            }
            self.homeManagerModules.default
            {
              config.programs.pkspec.enable = true;
            }
          ];
        };
      in {
        packages = {
          default = pkspec;
          pkspec = pkspec;
          pkl-native = pklNative;
        };

        apps.default = {
          type = "app";
          program = "${pkspec}/bin/pkspec";
          meta = pkspec.meta;
        };

        checks = {
          native-pkl = pkgs.runCommand "pkl-native-check" { } ''
            ${pklNative}/bin/pkl --version > version.txt
            if ! grep -E -i 'native' version.txt; then
              echo "pkl-native did not report a native runtime" >&2
              exit 1
            fi
            if grep -E -i -- '-(temurin|openjdk|jdk|jre)' ${pklNativeClosure}/store-paths; then
              echo "pkl-native closure unexpectedly contains a Java runtime" >&2
              exit 1
            fi
            cp version.txt "$out"
          '';

          pkspec-no-java-closure = pkgs.runCommand "pkspec-no-java-closure-check" { } ''
            ${pkspec}/bin/pkspec version > version.txt
            if grep -E -i -- '-(temurin|openjdk|jdk|jre)' ${pkspecClosure}/store-paths; then
              echo "pkspec closure unexpectedly contains a Java runtime" >&2
              exit 1
            fi
            cp version.txt "$out"
          '';

          home-manager-module = pkgs.runCommand "pkspec-home-manager-module-check" { } ''
            packages="${toString homeManagerModuleEval.config.home.packages}"
            case "$packages" in
              *pkspec* ) ;;
              * ) echo "home-manager module did not install pkspec" >&2; exit 1 ;;
            esac
            case "$packages" in
              *pkl-native* ) ;;
              * ) echo "home-manager module did not install native pkl" >&2; exit 1 ;;
            esac
            touch "$out"
          '';
        };

        # `nix develop` for working on pkspec itself.
        devShells.default = pkgs.mkShell {
          packages = [
            pkfire.packages.${system}.default
          ] ++ (with pkgs; [
            go_1_26_3
            pklNative
            gopls
          ]);
        };
      }) // {
        homeManagerModules.default = import ./nix/home-manager.nix { inherit self; };
        homeManagerModules.pkspec = self.homeManagerModules.default;
      };
}
