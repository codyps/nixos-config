{ config, pkgs, ... }:
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

  # Keep GPG's path stable without re-signing the Nix-built application. The
  # previous Apple Development certificate was revoked, causing macOS to trash
  # the signed copy. A structurally valid signature or find-identity output
  # does not establish revocation status. Keychain permissions may need renewing
  # after package upgrades until a valid persistent signing identity is available.
  home.file.".local/libexec/pinentry-mac.app" = {
    source = "${pkgs.pinentry_mac}/Applications/pinentry-mac.app";
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
