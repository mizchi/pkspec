{
  lib,
  stdenv,
  fetchurl,
  autoPatchelfHook,
  zlib,
}:

let
  version = "0.31.1";
  platforms = {
    x86_64-linux = {
      asset = "linux-amd64";
      hash = "sha256-YY8TlV11XK+/6MnLodJ2NYSM1J28ar/9OY0nUdsSMb8=";
    };
    aarch64-linux = {
      asset = "linux-aarch64";
      hash = "sha256-fvEOdD2qkh+5Sue9uexphvNivyUMVYFLnqKusT8tCD4=";
    };
    x86_64-darwin = {
      asset = "macos-amd64";
      hash = "sha256-IhI+1K5MA6+oxUxp938L7Dmw+g9nsJ1tFI4KN2oqRx0=";
    };
    aarch64-darwin = {
      asset = "macos-aarch64";
      hash = "sha256-G2pUONliTNJ5inUwchu7+ifvcu/lyHihtsVGxufKDo8=";
    };
  };
  platform =
    platforms.${stdenv.hostPlatform.system}
      or (throw "pkl-native: unsupported system ${stdenv.hostPlatform.system}");
in
stdenv.mkDerivation {
  pname = "pkl-native";
  inherit version;

  src = fetchurl {
    url = "https://github.com/apple/pkl/releases/download/${version}/pkl-${platform.asset}";
    inherit (platform) hash;
  };

  dontUnpack = true;
  nativeBuildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    autoPatchelfHook
  ];
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.libc
    zlib
  ];

  installPhase = ''
    runHook preInstall

    install -Dm755 "$src" "$out/bin/pkl"

    runHook postInstall
  '';

  meta = {
    description = "Native Pkl CLI binary";
    homepage = "https://pkl-lang.org";
    downloadPage = "https://github.com/apple/pkl/releases";
    license = lib.licenses.asl20;
    mainProgram = "pkl";
    platforms = builtins.attrNames platforms;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
