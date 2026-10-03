{ pkgs, ... }:
{
  # Bootstrap once, outside activation and without delaying the AI services.
  # Existing defaults and repository-specific rust-toolchain.toml files win.
  systemd.services.ai-rust = {
    description = "Initialize the AI account's Rustup toolchain";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
    unitConfig.RequiresMountsFor = [ "/home/cody-ai" ];
    environment = {
      HOME = "/home/cody-ai";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "cody-ai";
      Group = "cody-ai";
      WorkingDirectory = "/home/cody-ai";
      Restart = "on-failure";
      RestartSec = 60;
      UMask = "0077";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = "tmpfs";
      BindPaths = [ "/home/cody-ai" ];
      PrivateTmp = true;
    };
    script = ''
      if ! ${pkgs.rustup}/bin/rustup default >/dev/null 2>&1; then
        ${pkgs.rustup}/bin/rustup toolchain install stable --profile minimal
        ${pkgs.rustup}/bin/rustup default stable
      fi
    '';
  };
}
