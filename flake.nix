{
  description = "pkspec — language-agnostic test runner that extends pkl test";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # MoonBit toolchain for the `nix develop` shell (building pkspec-mbt/
    # from source). The package itself no longer builds from source — it
    # installs the prebuilt release binaries — so there is no Go input.
    moonbit-overlay.url = "github:moonbit-community/moonbit-overlay";
  };

  outputs = { self, nixpkgs, flake-utils, moonbit-overlay }:
    let
      # pkspec is distributed as prebuilt MoonBit binaries (the pkspec CLI
      # plus five adapter shims). This flake installs the release tarball
      # rather than compiling from source — the same artifact `install.sh` /
      # the GitHub Action ship.
      #
      # `version` + the per-platform sha256 live in `nix/pkspec-release.json`,
      # which the release workflow (.github/workflows/mbt-publish.yml) auto-
      # regenerates from the freshly built checksums and opens a follow-up PR
      # for. To bump by hand: set version, then refresh each sha256 from
      #   curl -fsSL https://github.com/mizchi/pkspec/releases/download/pkspec@<v>/pkspec-<plat>.tar.gz.sha256
      # (no x86_64-darwin: the MoonBit toolchain has no Intel macOS build.)
      #
      # NOTE: until the pkspec@<version> release exists, the sha256 fields in
      # nix/pkspec-release.json are zeroed placeholders — `nix build` will
      # fail with a hash mismatch until the release workflow fills them in.
      release = builtins.fromJSON (builtins.readFile ./nix/pkspec-release.json);
      version = release.version;
      assets = release.platforms;

      # The six binaries packed into pkspec-<plat>.tar.gz.
      binaries = [
        "pkspec"
        "pkspec-adapter-vitest"
        "pkspec-adapter-playwright"
        "pkspec-adapter-node-test"
        "pkspec-adapter-go-test"
        "pkspec-adapter-moon-test"
      ];
    in
    flake-utils.lib.eachSystem (builtins.attrNames assets) (system:
      let
        pkgs = import nixpkgs { inherit system; };
        asset = assets.${system};
        isLinux = pkgs.stdenv.hostPlatform.isLinux;
        pklNative = pkgs.callPackage ./nix/pkl-native.nix { };

        tarball = pkgs.fetchurl {
          url = "https://github.com/mizchi/pkspec/releases/download/pkspec@${version}/pkspec-${asset.plat}.tar.gz";
          sha256 = asset.sha256;
        };

        # Install the prebuilt binaries. On Linux they were built on a
        # generic runner, so autoPatchelfHook rewrites the ELF interpreter +
        # rpath for the Nix closure. Two runtime wraps per binary:
        #   1. `pkspec` shells out to `pkl` (and re-invokes itself), so keep
        #      the native pkl on PATH.
        #   2. moonbitlang/async's TLS module dlopen()s libssl.so.3 at startup
        #      (unconditional). dlopen consults LD_LIBRARY_PATH (not
        #      DT_RUNPATH), so autoPatchelf can't help — put openssl on
        #      LD_LIBRARY_PATH. macOS dlopen's /usr/lib system libssl, so this
        #      is Linux-only.
        pkspec = pkgs.stdenv.mkDerivation {
          pname = "pkspec";
          inherit version;
          src = tarball;
          dontUnpack = true;

          nativeBuildInputs = [ pkgs.makeWrapper ]
            ++ pkgs.lib.optionals isLinux [ pkgs.autoPatchelfHook ];
          # autoPatchelfHook resolves the binaries' NEEDED libs against these.
          buildInputs = pkgs.lib.optionals isLinux [ pkgs.stdenv.cc.cc.lib ];

          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin
            tar -xzf "$src"
            for bin in ${pkgs.lib.escapeShellArgs binaries}; do
              install -m 0755 "$bin" "$out/bin/$bin"
            done
            runHook postInstall
          '';

          postFixup = ''
            for bin in ${pkgs.lib.escapeShellArgs binaries}; do
              wrapProgram "$out/bin/$bin" \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pklNative ]} \
                ${pkgs.lib.optionalString isLinux
                  "--prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath [ pkgs.openssl ]}"}
            done
          '';

          meta = with pkgs.lib; {
            description = "Language-agnostic test runner that extends pkl test";
            homepage = "https://github.com/mizchi/pkspec";
            license = licenses.mit;
            mainProgram = "pkspec";
            platforms = builtins.attrNames assets;
          };
        };

        pklNativeClosure = pkgs.closureInfo {
          rootPaths = [ pklNative ];
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

        # `nix develop` for working on pkspec itself: the MoonBit toolchain
        # (`moon`, `moonc`, …) to build `pkspec-mbt/` from source, plus the
        # native Pkl CLI (needed for `pkl test` / `pkl format`).
        devShells.default = pkgs.mkShell {
          packages = [
            moonbit-overlay.packages.${system}.default
            pklNative
          ];
        };
      }) // {
        homeManagerModules.default = import ./nix/home-manager.nix { inherit self; };
        homeManagerModules.pkspec = self.homeManagerModules.default;
      };
}
