environment.etc."nix/ssh_config".text = ''
    Host arnold-tailscale
      User nix
      HostName 100.96.147.23
      IdentityFile /etc/nix/keys/arnold_ed25519
      UserKnownHostsFile /etc/nix/ssh_known_hosts.d/arnold
  '';

nix.buildMachines = [{
hostName = "arnold-tailscale";
systems = ["x86_64-linux" "aarch64-linux"];
maxJobs = 4;
supportedFeatures = [ "nixos-test" "benchmark" "big-parallel" "kvm" ];
protocol = "ssh-ng";
}];

environment.etc."nix/ssh_known_hosts.d/arnold".text = ''
    192.168.6.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFLLtofc9hAToGZfafrlv8/4tE5W0IARQ8nHs8DpBMSk
  '';
