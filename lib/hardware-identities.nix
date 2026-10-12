# Hardware data is an explicit flake input, never ambient state or a SOPS build.
input:
let
  metadata = builtins.fromJSON (builtins.readFile (input + "/metadata.json"));
  values = builtins.fromJSON (builtins.readFile (input + "/hardware-identities.json"));
  schema = builtins.fromJSON (builtins.readFile ./hardware-identities-schema.json);
  fixtures = builtins.fromJSON (builtins.readFile ../config/hardware-fixtures/hardware-identities.json);
  matches = schema: value:
    if builtins.isAttrs schema then
      builtins.isAttrs value && builtins.attrNames schema == builtins.attrNames value
      && builtins.all (key: matches schema.${key} value.${key}) (builtins.attrNames schema)
    else if schema == "integer" then builtins.isInt value && value >= 0 && value <= 4294967295
    else if schema == "volume-key-id" && value == null then true
    else builtins.isString value && builtins.match {
      uuid = "[0-9a-fA-F-]+";
      host-id = "[0-9a-fA-F]{8}";
      volume-key-id = "[0-9a-fA-F]{64}";
      mac-address = "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}";
      duid = "([0-9a-fA-F]{2}:)*[0-9a-fA-F]{2}";
      device-id = "[a-zA-Z0-9_.:+-]+";
      usb-hash = "[A-Za-z0-9+/]{43}=";
    }.${schema}
      value != null;
in
assert metadata.version == 1 && builtins.isBool metadata.fixture;
assert matches schema values;
assert !metadata.fixture || values == fixtures;
{
  # Copying fixtures and changing their marker must not make them deployable.
  fixture = metadata.fixture || values == fixtures;
  inputPath = toString input;
  inherit values;
  get = host: path: builtins.foldl' (value: key: builtins.getAttr key value) values.${host} path;
}
