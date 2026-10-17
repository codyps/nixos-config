{ pkgs, ... }:
{
  # Both the host sandbox and the container have this account, but separate
  # persistent homes. Run as the account so user-owned paths stay unprivileged.
  # Change only identity keys; retain credential helpers and other preferences.
  system.activationScripts.aiGitIdentity = {
    deps = [ "users" "etc" ];
    text = ''
      ${pkgs.util-linux}/bin/runuser -u cody-ai -- \
        ${pkgs.git}/bin/git -C /home/cody-ai config --file /home/cody-ai/.gitconfig --replace-all user.name 'Cody P Schafer'
      ${pkgs.util-linux}/bin/runuser -u cody-ai -- \
        ${pkgs.git}/bin/git -C /home/cody-ai config --file /home/cody-ai/.gitconfig --replace-all user.email 'dev@codyps.com'
    '';
  };
}
