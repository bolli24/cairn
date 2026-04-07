{pkgs ? import <nixpkgs> {}}:
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    zig
    pkg-config
  ];
  buildInputs = with pkgs; [
    alsa-lib
    libGL
    xorg.libX11
    xorg.libXcursor
    xorg.libXrender
    xorg.libXfixes
    xorg.libXi
    wayland
    libxkbcommon
  ];
}
