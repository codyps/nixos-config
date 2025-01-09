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

  config.services.komga.settings.server.address = lib.mkDefault config.services.defaultBindAddress;
}
