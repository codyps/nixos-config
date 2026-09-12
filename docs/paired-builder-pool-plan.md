# Cryptographically paired Nix builder pool

Status: proposed; implementation and activation are pending.

## Objective

Build a Rust service that pairs builders cryptographically, tracks their
availability, and exposes them to Nix through local Unix sockets. Nix retains
responsibility for derivation scheduling, input transfer, execution, and output
retrieval. Enrollment and network transport do not depend on SSH.

A machine remains linked while offline. Only available builders enter the
generated machines list. On-demand builders remain eligible through an activation
agent without starting their backend during heartbeat or readiness checks.

## Initial architecture

Use one coordinator with relay transport, explicit invitations, and outbound
connections from builder agents. Provide coordinator, agent, and administrative
commands in one standalone Rust package, with separate transport, membership, and
Nix-integration components.

```text
Nix scheduler
  -> protected local Unix socket for a builder
  -> authenticated relay transport through the coordinator
  -> builder agent
  -> remote nix-daemon
```

The local adapter maintains stable socket names and an atomic machines file.
Additional client adapters authenticate with an explicitly authorized client role.
Builder enrollment does not grant client or administrative privileges.

Lix 2.94.2 source inspection indicates that the stock builder implementation opens
generic store URIs and supports Unix-socket stores. Actual remote builds through
this transport must be demonstrated before treating this architecture as proven.
Compatibility with other Nix/Lix releases must be tested explicitly.

## Implementation milestones

### 1. Prove the Nix transport

- Forward a local `unix://` store connection over mutual TLS to a remote daemon.
- Use established TLS and certificate libraries, initially with test credentials.
- Establish which remote account and daemon permissions the agent requires.
  Document the authority granted by forwarding access to that daemon.
- Preserve connection isolation, structured logs, and cancellation semantics.

Acceptance: a real derivation scheduled by stock Lix transfers inputs, builds
remotely, and returns usable outputs. Concurrent builds and cancellation work;
broken connections terminate within a bounded interval. This milestone gates the
enrollment implementation.

### 2. Create the Rust package and interfaces

- Add a standalone package with coordinator, builder-agent, and administrative
  commands.
- Separate transport, persistent membership, and machines-file generation.
- Define versioned application messages and reject unsupported protocol versions.
- Make runtime directories, persistent state, listening addresses, and deadlines
  explicit configuration.

Acceptance: components can be exercised independently using temporary state and
local test endpoints on Linux and macOS.

### 3. Implement cryptographic linking

- The coordinator generates a short-lived invitation with its address, pinned
  identity, and a high-entropy enrollment token.
- The builder generates its private key locally and authenticates the coordinator
  using the invitation's pin.
- Enrollment proves possession of the builder key and atomically consumes the
  single-use token before issuing a builder certificate.
- Transfer invitations through a trusted channel. Do not expose tokens or private
  keys through command-line arguments or logs; store secrets with restrictive
  permissions.

Acceptance: valid enrollment succeeds; expired or replayed invitations, an
incorrect coordinator identity, and concurrent attempts to reuse a token fail.

### 4. Persist membership and enforce authorization

- Persist linked identities, certificate status, and authorized roles.
- Support listing members, unlinking, certificate renewal, and coordinator restart.
- Unlinking blocks new sessions and closes existing sessions for that identity.
- Define certificate expiration, renewal, and trust-root recovery behavior.
- Separate builder, build-client, and administrator permissions.

Acceptance: membership survives restart; revoked identities cannot reconnect;
renewal works without repeating enrollment; role boundaries are enforced.

### 5. Track availability through agent sessions

- Maintain outbound authenticated agent connections with bounded reconnect backoff.
- Advertise supported systems, features, and job capacity under the linked identity.
- Distinguish offline, starting, ready, and draining states.
- Require a live session and backend readiness before publishing availability.
- Expire availability after missed heartbeats and restore it after reconnection.
- Treat capability advertisements as claims from an authorized builder, not proof
  of hardware capabilities or correctness of its outputs.

Acceptance: disconnects remove eligibility within the configured deadline;
reconnections restore it without relinking. Draining prevents new assignments
while allowing existing work to finish.

### 6. Integrate the dynamic machines list

- Expose one protected local Unix socket per available builder with stable names.
- Atomically publish the machines file without restarting the Nix daemon.
- Reuse the existing `nix-dynamic-machines` renderer where practical; explicitly
  extend its current SSH-only validation for managed Unix-socket endpoints.
- Preserve system types, features, relative speeds, and job limits.
- Enforce aggregate capacity at the builder when multiple clients share it;
  per-client `maxJobs` alone is insufficient.

Acceptance: an ordinary Nix build selects an eligible paired builder, skips an
offline builder, and picks up membership changes without daemon restart.
Concurrent clients cannot exceed the agreed builder capacity.

### 7. Preserve on-demand Docker activation

- Add an activation adapter for the existing Docker Linux builder.
- Keep the agent available while the container sleeps.
- Heartbeats and readiness checks inspect activation readiness without connecting
  to or launching the sleeping backend.
- Start the container only for a build connection, serialize concurrent startup,
  and use a separate startup deadline.
- Preserve the existing active-work protection and idle shutdown behavior.

Acceptance: repeated idle reconciliation and heartbeats never start Docker. A
real Linux build starts it, concurrent requests share startup, and idle shutdown
still works afterward.

### 8. Define failure behavior and diagnostics

- Reject new connections promptly when the builder is unavailable.
- Bound connection establishment and detect broken sessions without limiting
  healthy, quiet builds by wall time or log activity.
- Report mid-build disconnects clearly; initially leave retries to the caller to
  avoid silently duplicating remote work.
- Show identity, availability, capabilities, and last failure in status output.
- Ensure unavailable coordinator/agent behavior is observable and that stale
  local sockets fail promptly rather than hanging Nix.

Acceptance: failures have bounded detection and useful diagnostics; no claim of
transparent migration or guaranteed retry of an in-progress derivation is made.

### 9. Test and package

- Cover pairing, token expiry/replay, wrong identities, revocation, renewal,
  reconnects, concurrent builds, cancellation, and daemon restart.
- Include the regression proving periodic activity never starts Docker.
- Export the package through the existing flake, preserving the separate Intel
  Darwin package set.
- Provide opt-in NixOS and nix-darwin modules for services, state directories,
  permissions, and Nix configuration.
- Run Rust tests and lint, affected Nix evaluations and builds, and live transport
  tests on compatible Linux and macOS runners.

Acceptance: package and integration checks pass on the supported platforms.
Report evaluation, build, activation, and live verification separately.

### 10. Roll out incrementally

- Start with one client and one remote builder.
- Add the Docker activation adapter, then a second client.
- Preserve a straightforward rollback to the existing builder configuration.
- Activate only after the package and integration checks pass; verify the actual
  selected builder and returned outputs during rollout.

Acceptance: the initial fleet builds successfully through paired connections,
offline members stop receiving new work, and rollback has been exercised.

## Trust and scope

Pairing authorizes a machine to supply build artifacts; it does not prove that its
outputs are correct. Only approved machines should join the trusted builder pool.
The coordinator is part of the initial trust boundary and relay availability path.

Direct peer connections, automatic LAN discovery, coordinator high availability,
and transparent build retries are deferred until enrollment and the Nix transport
are proven. No host has been configured or activated by this plan.

## Existing repository components

- `scripts/nix-dynamic-machines/`: current Rust probe-and-render utility.
- `nixpkgs/overlays/pkgs/nix-dynamic-machines.nix`: existing package expression.
- `scripts/docker-linux-builder/`: Docker activation and idle lifecycle code.
- `hosts/u3/darwin.nix`: current Docker builder and remote fallback configuration.
- `modules/build-machines.nix`: shared builder declarations.
