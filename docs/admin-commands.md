# Repository administration commands

Use `sys COMMAND [ARGUMENT ...]` for custom user-facing operations provided by
this configuration. `sys help` (or `sys --list`) lists installed commands.
For example, Warbler exposes `sudo sys setup-luks-tpm-unlock`; u3 exposes
`sudo sys nix-maintenance`. Commands are available after rebuilding and activating
the affected system or Home Manager configuration.

Register commands in the module that owns the operation:

```nix
imports = [ ../modules/admin-commands.nix ];
programs.adminCommands.commands.setup-example = [
  "${helper}/bin/example-helper"
  "setup"
];
```

Use a descriptive kebab-case name and an absolute store path to the executable.
The list contains the executable followed by fixed arguments; user arguments
are forwarded verbatim. Register commands conditionally when their feature is
enabled. Keep existing helper names when services or scripts depend on them.
Upstream command wrappers (such as `cargo` or `codex`) and private service/PAM
entry points keep the names their callers require.

The shared module works with NixOS, nix-darwin, and Home Manager. It installs
`sys` plus `sys-COMMAND` executables. The dispatcher discovers these executables
beside the invoked `sys` launcher and then on PATH, so system and user commands
appear together. The first occurrence wins if names overlap. An explicit
generation's `sw/bin/sys` therefore selects that generation's helpers before
those on PATH. Use unique operation names across modules. `sudo sys`
uses sudo's PATH and therefore exposes system commands, not necessarily commands
installed only in a user profile. No automatic privilege escalation is added.

New user-facing custom administration helpers must register here and use `sys`
in their documentation. Repository development scripts and flake-only installer
or remote-build entry points can retain their existing invocation until packaged
for an installed host.
