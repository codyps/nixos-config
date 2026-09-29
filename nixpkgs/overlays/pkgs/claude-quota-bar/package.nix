{ lib, stdenv, swift, writeText }:
let
  infoPlist = writeText "Info.plist" (lib.generators.toPlist { escape = true; } {
    CFBundleExecutable = "claude-quota-bar";
    CFBundleIdentifier = "com.codyps.claude-quota-bar";
    CFBundleName = "Claude Quota Bar";
    CFBundlePackageType = "APPL";
    CFBundleShortVersionString = "1.0";
    # Menu bar only: no Dock icon or app menu.
    LSUIElement = true;
  });
in
stdenv.mkDerivation {
  pname = "claude-quota-bar";
  version = "1.0";

  src = ./main.swift;
  dontUnpack = true;

  nativeBuildInputs = [ swift ];

  buildPhase = ''
    runHook preBuild
    swiftc -O -o claude-quota-bar $src -framework AppKit
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    app="$out/Applications/Claude Quota Bar.app/Contents"
    install -Dm755 claude-quota-bar "$app/MacOS/claude-quota-bar"
    install -Dm644 ${infoPlist} "$app/Info.plist"
    mkdir -p $out/bin
    ln -s "$app/MacOS/claude-quota-bar" $out/bin/claude-quota-bar
    runHook postInstall
  '';

  meta = {
    description = "Menu bar gauge of Claude spend against quota and work days elapsed this month";
    platforms = lib.platforms.darwin;
    mainProgram = "claude-quota-bar";
  };
}
