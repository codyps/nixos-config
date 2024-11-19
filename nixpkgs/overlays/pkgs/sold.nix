{ mold, fetchFromGitHub }:
mold.overrideAttrs (old: rec {
  pname = "sold";
  src = prev.fetchFromGitHub {
    owner = "bluewhalesystems";
    repo = pname;
    rev = "760d17400aebf838b7a6284d3191cd8c5f344ca6";
    hash = "sha256-MjppW9xtPfGyoHWatK4NoKE0UFuEno+oNqy5zjxY1A4=";
  };

  postPatch = old.postPatch + ''
    sed -i CMakeLists.txt -e '/.*install(FILES LICENSE\ .*/d'
  '';

  enableParallelBuilding = true;
})
