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

  pinentry-mac-app = "${config.home.homeDirectory}/.local/libexec/pinentry-mac.app";
  pinentry-mac-program = "${pinentry-mac-app}/Contents/MacOS/pinentry-mac";

  # The newest valid Apple Development identity in the login Keychain. It is
  # valid through 2027-07-31; update this fingerprint after renewing it.
  pinentry-mac-signing-identity = "74BFF0F545B04980BDFBFF930E327BFC264A0F3C";
  pinentry-mac-signing-requirement =
    ''identifier "org.gpgtools.pinentry-mac" and anchor apple generic ''
    + ''and certificate leaf[subject.CN] = "Apple Development: cpschafer@gmail.com (VND7B2K25N)"'';
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

  programs.zsh.completionInit = "";

  # Keychain ACLs identify the executable reading a password by its designated
  # code-signing requirement. Sign a mutable copy with a certificate-backed
  # identity so "Always Allow" survives package rebuilds and agent restarts.
  home.activation.installSignedPinentryMac =
    lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ] ''
      target=${lib.escapeShellArg pinentry-mac-app}
      source=${pkgs.pinentry_mac}/Applications/pinentry-mac.app
      source_marker="$target.source"
      requirement=${lib.escapeShellArg pinentry-mac-signing-requirement}

      if ! /usr/bin/codesign --verify --deep --strict \
        -R="$requirement" "$target" 2>/dev/null \
        || [[ "$(${pkgs.coreutils}/bin/readlink "$source_marker")" != "$source" ]]; then
        run /bin/mkdir -p "$(/usr/bin/dirname "$target")"
        run /bin/rm -rf "$target"
        run /bin/cp -R "$source" "$target"
        run /bin/chmod -R u+w "$target"
        run /usr/bin/codesign --force --deep --timestamp=none \
          --sign ${lib.escapeShellArg pinentry-mac-signing-identity} "$target"
        run /usr/bin/codesign --verify --deep --strict \
          -R="$requirement" "$target"
        run /bin/rm -f "$source_marker"
        run /bin/ln -s "$source" "$source_marker"
      fi
    '';

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
