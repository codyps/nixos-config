{ pkgs, ... }:
{
  programs.git = {
    enable = true;
    config.credential = {
      "https://github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";
      "https://gist.github.com".helper = "!${pkgs.gh}/bin/gh auth git-credential";
    };
  };
}
