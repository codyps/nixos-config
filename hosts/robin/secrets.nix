{ config, lib, ... }:
{
  sops = {
    defaultSopsFile = ./secrets.yaml;
    # Available before user creation because /persist is neededForBoot.
    age.sshKeyPaths = [ "/persist/ssh/ssh_host_ed25519_key" ];
    gnupg.sshKeyPaths = [ ];
    secrets = {
      cloudflare-api-key-einic-org-dns = { };
      root-password-hash.neededForUsers = true;
      cody-password-hash.neededForUsers = true;
    };
    templates."caddy-env" = {
      restartUnits = [ "caddy.service" ];
      content = ''
        CLOUDFLARE_API_TOKEN=${config.sops.placeholder.cloudflare-api-key-einic-org-dns}
      '';
    };
  };

  # A disposable VM must not need production decryption keys or credentials.
  virtualisation.vmVariantWithDisko = {
    sops.secrets = lib.mkForce { };
    sops.templates = lib.mkForce { };
    users.users.root.hashedPasswordFile = lib.mkForce null;
    users.users.cody.hashedPasswordFile = lib.mkForce null;
    systemd.services.caddy.serviceConfig.EnvironmentFile = lib.mkForce [ ];
    services.caddy.enable = lib.mkForce false;
    boot.initrd.network.ssh.enable = lib.mkForce false;
  };
}
