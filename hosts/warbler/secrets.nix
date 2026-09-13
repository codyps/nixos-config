{ ... }:
{
  # Same identity as stage-2 sshd, available before users are created because
  # /persist is neededForBoot. Never use the separate TPM-sealed initrd key.
  sops.age.sshKeyPaths = [ "/persist/ssh/ssh_host_ed25519_key" ];
  sops.gnupg.sshKeyPaths = [ ];
  # Declare sopsFile per secret until this host has a production secrets file.
}
