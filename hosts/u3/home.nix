{ config, lib, pkgs, ... }:
let
  shizuku-usb-watch = pkgs.writeShellApplication {
    name = "shizuku-usb-watch";
    runtimeInputs = with pkgs; [
      android-tools
      coreutils
    ];
    text = builtins.readFile ../../scripts/shizuku-usb-watch.sh;
  };

  fix-copilot-keychain-acl = pkgs.writeScriptBin "fix-copilot-keychain-acl"
    (builtins.readFile ../../scripts/fix-copilot-keychain-acl.swift);

  pinentry-mac-app = "${config.home.homeDirectory}/.local/libexec/pinentry-mac.app";
  pinentry-mac-program = "${pinentry-mac-app}/Contents/MacOS/pinentry-mac";
  signed-pinentry-mac = pkgs.runCommand "pinentry-mac-adhoc-${pkgs.pinentry_mac.version}" { } ''
    mkdir -p "$out/Applications"
    cp -R "${pkgs.pinentry_mac}/Applications/pinentry-mac.app" "$out/Applications/"
    app="$out/Applications/pinentry-mac.app"
    chmod -R u+w "$app"
    /usr/bin/codesign --force --sign - --timestamp=none "$app"
    /usr/bin/codesign --verify --strict "$app"
  '';

  read-keychain-partitions = pkgs.stdenv.mkDerivation {
    name = "read-keychain-partitions";
    buildCommand = ''
      mkdir -p "$out/bin"
      clang -fobjc-arc -Wno-deprecated-declarations -framework Foundation -framework Security \
        ${../../scripts/read-keychain-partitions.m} -o "$out/bin/read-keychain-partitions"
    '';
  };

  update-pinentry-keychain-partition = pkgs.writeShellApplication {
    name = "update-pinentry-keychain-partition";
    runtimeInputs = [ pkgs.gawk pkgs.gnupg read-keychain-partitions ];
    text = ''
      declare keygrip cdhash existing status
      keychain=${lib.escapeShellArg "${config.home.homeDirectory}/Library/Keychains/login.keychain-db"}
      signing_key=${lib.escapeShellArg config.programs.git.signing.key}
      pinentry=${lib.escapeShellArg "${signed-pinentry-mac}/Applications/pinentry-mac.app/Contents/MacOS/pinentry-mac"}
      [[ -f "$keychain" ]] || exit 0

      keygrip=$(gpg --batch --no-auto-check-trustdb --with-colons --with-keygrip --list-keys "$signing_key" |
        awk -F: -v key="$signing_key" '$1 == "fpr" { matchKey = ($10 == key) }
          $1 == "grp" && matchKey { print $10; matchKey = 0 }')
      [[ "$keygrip" =~ ^[0-9A-F]{40}$ ]] || exit 1

      if existing=$(read-keychain-partitions "$keychain" GnuPG "$keygrip"); then
        :
      else
        status=$?
        [[ "$status" == 2 ]] && exit 0
        exit "$status"
      fi

      cdhash=$(/usr/bin/codesign -d --verbose=4 "$pinentry" 2>&1 |
        awk -F= '$1 == "CDHash" { print $2 }')
      [[ "$cdhash" =~ ^[0-9a-f]{40}$ ]] || exit 1
      partition="cdhash:$cdhash"
      [[ ",$existing," != *",$partition,"* ]] || exit 0

      if [[ ! -t 0 || ! -t 2 ]]; then
        printf '%s\n' 'Pinentry Keychain authorization needs an interactive Home Manager activation.' >&2
        exit 0
      fi

      printf '%s\n' 'Authorize the current pinentry-mac build with your login Keychain password.' >&2
      /usr/bin/security set-generic-password-partition-list -s GnuPG -a "$keygrip" \
        -S "''${existing:+$existing,}$partition" "$keychain" >/dev/null
      existing=$(read-keychain-partitions "$keychain" GnuPG "$keygrip")
      [[ ",$existing," == *",$partition,"* ]]
    '';
  };
in
{

  # NOTE: to tweak this, `nvm` must be disabled
  #home.sessionVariables.NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/.local";

  #home.sessionPath = [
  #  "${config.home.homeDirectory}/.local/bin"
  #];

  # NVM is _very_ slow to load: 1 second delay on shell opening if we load it
  # in zshrc. So delay it until first use. This is probably fine unless it
  # tweaks my path on init.
  #programs.zsh.initContent = ''
  #  export NVM_DIR="$HOME/.nvm"

  #  _nvm_lazy_load() {
  #    unfunction nvm node npm npx corepack 2>/dev/null
  #    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  #      print -u2 "NVM is not installed at $NVM_DIR"
  #      return 127
  #    fi
  #    . "$NVM_DIR/nvm.sh"
  #  }

  #  nvm() { _nvm_lazy_load || return; nvm "$@"; }
  #  node() { _nvm_lazy_load || return; node "$@"; }
  #  npm() { _nvm_lazy_load || return; npm "$@"; }
  #  npx() { _nvm_lazy_load || return; npx "$@"; }
  #  corepack() { _nvm_lazy_load || return; corepack "$@"; }
  #'';

  # Give Keychain a code identity for this build without relying on the local
  # Apple Development certificate. Upgrades can change the ad hoc identity.
  home.file.".local/libexec/pinentry-mac.app" = {
    source = "${signed-pinentry-mac}/Applications/pinentry-mac.app";
    # Adopt the path previously populated by installSignedPinentryMac.
    force = true;
  };

  home.file.".gnupg/gpg-agent.conf" = {
    text = ''
      pinentry-program ${pinentry-mac-program}
    '';
    onChange = ''
      ${pkgs.gnupg}/bin/gpgconf --reload gpg-agent
    '';
  };

  home.activation.updatePinentryKeychainPartition = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if ! run ${update-pinentry-keychain-partition}/bin/update-pinentry-keychain-partition; then
      printf '%s\n' 'Could not update the pinentry Keychain partition. Rerun activation to retry.' >&2
    fi
  '';

  home.sessionVariables.JAVA_HOME = "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home";
  home.sessionPath = [
    "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home/bin"
  ];

  home.packages = with pkgs; [
    josm
    gh
    shizuku-usb-watch
    fix-copilot-keychain-acl
  ];

  launchd.agents.shizuku-usb-watch = {
    enable = true;
    config = {
      ProgramArguments = [ "${shizuku-usb-watch}/bin/shizuku-usb-watch" ];
      EnvironmentVariables.HOME = config.home.homeDirectory;
      ProcessType = "Background";
      RunAtLoad = true;
      KeepAlive = true;
      StandardOutPath = "${config.home.homeDirectory}/Library/Logs/shizuku-usb-watch.log";
      StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/shizuku-usb-watch-error.log";
    };
  };

  #programs.codex = {
  #enable = true;
  #settings = {
  # FIXME: we _probably_ need to wrap codex (and give it a custom bash
  # wrapper) to work around some of these.
  #
  # The use of bash login shell
  # screwing up environment could be worked around by hooking the
  # particular call codex does and not actually running a login shell.
  # Instead, we could just use a normal shell.
  #
  # sccache not working due to network blocking is attempted to be worked
  # around by the sandbox disables.
  #
  # similar for nix.
  #
  # The shell_environment_policy is to try to get direnv working
  #
  # https://github.com/openai/codex/issues/4843#issuecomment-3533072321
  # https://github.com/openai/codex/issues/25452
  # https://github.com/openai/codex/issues/4210
  # https://github.com/openai/codex/issues/16910
  #sandbox_workspace_write = {
  #  network_access = true;
  #  sandbox_mode = "workspace-write";
  #};
  #shell_environment_policy = {
  #  "inherit" = "all";
  #  ignore_default_excludes = true;
  #};
  #};
  #};
}
