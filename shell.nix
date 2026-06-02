{pkgs ? import <nixpkgs> {}}:

let
  lib = pkgs.lib;
  cInputs = [ pkgs.glibc ];
  runtimeInputs = with pkgs; [
    alsa-lib
    libGL
    libx11
    libxcursor
    libxrender
    libxfixes
    libxi
    libxext
    libxau
    libxdmcp
    xorgproto
    wayland
    libxkbcommon
  ];
in

assert lib.assertMsg (lib.versionAtLeast pkgs.zig.version "0.16")
  "cairn requires Zig 0.16 or newer; use a nixpkgs that provides it";

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    zig
    pkg-config
  ];
  buildInputs = runtimeInputs;

  shellHook = ''
    export NIX_CFLAGS_COMPILE="${lib.concatMapStringsSep " " (pkg: "-isystem ${lib.getDev pkg}/include") (cInputs ++ runtimeInputs)}"
    export NIX_LDFLAGS="${lib.concatMapStringsSep " " (pkg: "-L${lib.getLib pkg}/lib") (cInputs ++ runtimeInputs)}"
    export PKG_CONFIG_PATH="${lib.makeSearchPathOutput "dev" "lib/pkgconfig" runtimeInputs}:${lib.makeSearchPathOutput "dev" "share/pkgconfig" runtimeInputs}"
  '';
}
