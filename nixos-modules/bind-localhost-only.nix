# Make every network service bind localhost by default
{ config, lib, ... }:
{
  options = {
    services.defaultBindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = ''
        The default address to bind services to.
      '';
    };

  };

  # NOTE: komga in nixos doesn't like ipv6. Investigate later.
  config.services.komga.settings.server.address = lib.mkDefault config.services.defaultBindAddress;

  config.services.grafana.settings.server.http_addr = lib.mkDefault config.services.defaultBindAddress;

  # TODO: determine if we can/should use an ip.
  config.services.hydra.listenHost = lib.mkDefault "localhost";

  # TODO: ipv6 vs ipv4? (I copied this from my existing config)
  # TODO: grab the default port from somewhere? (this is _probably_ not the default)
  config.services.harmonia.settings.bind = lib.mkDefault "[::1]:8916";

  # TODO: ipv6 vs ipv4? (I copied this from my existing config)
  # TODO: grab the default port from somewhere? (this is _probably_ not the default)
  config.services.atticd.settings.listen = lib.mkDefault "[::1]:8915";

  config.services.kavita.settings.IpAddresses = lib.mkDefault "127.0.0.1,::1";
}
