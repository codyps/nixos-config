{ usbguard }:
usbguard.overrideAttrs (old: {
  # Protobuf 36's Abseil headers require C++20; USBGuard 1.1.4 hard-codes
  # C++17 in configure.ac, including the bundled PEGTL/Catch flag setup.
  postPatch = (old.postPatch or "") + ''
    substituteInPlace configure.ac --replace-fail '-std=c++17' '-std=c++20'
  '';
})
