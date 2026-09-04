#!/usr/bin/env -S swift -suppress-warnings

import Darwin
import Foundation
import Security

private let defaultService = "copilot-language-server"
private let defaultAccount = "oauth-token-key"
private let expectedNodeTeamID = "HX7739G8FX"

private struct Options {
  var nodeCommand = NSHomeDirectory() + "/.local/share/vite-plus/bin/node"
  var keychain = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
  var service = defaultService
  var account = defaultAccount
  var dryRun = false
}

private struct CommandResult {
  let status: Int32
  let stdout: String
  let stderr: String
}

private enum RepairError: Error, CustomStringConvertible {
  case message(String)

  var description: String {
    switch self {
    case .message(let message):
      return message
    }
  }
}

private func usage() {
  print("""
  Usage: fix-copilot-keychain-acl.swift [options]

  Trust the signed Node runtime used by Vite+ to read Copilot's existing
  Keychain master-key item. The script never reads or changes the stored secret
  and never signs or otherwise modifies Node.

  Options:
    --node-command PATH  Node launcher used to discover process.execPath
                         (default: ~/.local/share/vite-plus/bin/node)
    --keychain PATH      Keychain containing the item
                         (default: ~/Library/Keychains/login.keychain-db)
    --service NAME       Generic-password service (default: \(defaultService))
    --account NAME       Generic-password account (default: \(defaultAccount))
    --dry-run            Verify and report without changing the ACL
    -h, --help           Show this help

  If the partition list needs updating, macOS's security tool will securely
  prompt for the login Keychain password. Do not pass a password on the command
  line.
  """)
}

private func parseOptions() throws -> Options {
  var options = Options()
  let arguments = Array(CommandLine.arguments.dropFirst())
  var index = 0

  func value(after option: String) throws -> String {
    let valueIndex = index + 1
    guard valueIndex < arguments.count else {
      throw RepairError.message("Missing value for \(option)")
    }
    index = valueIndex
    return arguments[valueIndex]
  }

  while index < arguments.count {
    switch arguments[index] {
    case "--node-command":
      options.nodeCommand = try value(after: arguments[index])
    case "--keychain":
      options.keychain = try value(after: arguments[index])
    case "--service":
      options.service = try value(after: arguments[index])
    case "--account":
      options.account = try value(after: arguments[index])
    case "--dry-run":
      options.dryRun = true
    case "-h", "--help":
      usage()
      exit(0)
    default:
      throw RepairError.message("Unknown option: \(arguments[index])")
    }
    index += 1
  }

  return options
}

private func runCaptured(_ executable: String, _ arguments: [String]) throws -> CommandResult {
  let process = Process()
  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe

  try process.run()
  process.waitUntilExit()

  let stdout = String(
    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
    encoding: .utf8
  ) ?? ""
  let stderr = String(
    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
    encoding: .utf8
  ) ?? ""
  return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

private func runInteractive(_ executable: String, _ arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.standardInput = FileHandle.standardInput
  process.standardOutput = FileHandle.standardOutput
  process.standardError = FileHandle.standardError
  try process.run()
  process.waitUntilExit()

  guard process.terminationStatus == 0 else {
    throw RepairError.message(
      "security set-generic-password-partition-list failed with status \(process.terminationStatus)"
    )
  }
}

private func trimmed(_ value: String) -> String {
  value.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func discoverNode(command: String) throws -> String {
  guard FileManager.default.isExecutableFile(atPath: command) else {
    throw RepairError.message("Node command is not executable: \(command)")
  }

  let result = try runCaptured(command, ["-p", "process.execPath"])
  guard result.status == 0 else {
    throw RepairError.message(
      "Could not discover Node from \(command): \(trimmed(result.stderr))"
    )
  }

  let path = trimmed(result.stdout)
  guard path.hasPrefix("/"), !path.contains("\n"), FileManager.default.isExecutableFile(atPath: path) else {
    throw RepairError.message("Node returned an invalid process.execPath: \(path)")
  }
  return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

private func verifySignedNode(at path: String) throws -> String {
  let verification = try runCaptured(
    "/usr/bin/codesign",
    ["--verify", "--strict", "--verbose=2", path]
  )
  guard verification.status == 0 else {
    throw RepairError.message(
      "Node does not have a valid strict code signature: \(trimmed(verification.stderr))"
    )
  }

  let details = try runCaptured("/usr/bin/codesign", ["-d", "--verbose=4", path])
  guard details.status == 0 else {
    throw RepairError.message("Could not inspect Node's code signature")
  }

  let teamPrefix = "TeamIdentifier="
  let teamID = details.stderr.split(separator: "\n").compactMap { line -> String? in
    guard line.hasPrefix(teamPrefix) else { return nil }
    return String(line.dropFirst(teamPrefix.count))
  }.first

  guard let teamID, !teamID.isEmpty, teamID != "not set" else {
    throw RepairError.message("Node has no certificate-backed TeamIdentifier")
  }
  let allowed = CharacterSet.uppercaseLetters.union(.decimalDigits)
  guard teamID.count == 10, teamID.unicodeScalars.allSatisfy(allowed.contains) else {
    throw RepairError.message("Node has an unexpected TeamIdentifier: \(teamID)")
  }
  guard teamID == expectedNodeTeamID else {
    throw RepairError.message(
      "Refusing to trust Node signed by unexpected team \(teamID); expected Node.js Foundation team \(expectedNodeTeamID)"
    )
  }
  return teamID
}

private func sha256(at path: String) throws -> String {
  let result = try runCaptured("/usr/bin/shasum", ["-a", "256", path])
  guard result.status == 0, let hash = result.stdout.split(separator: " ").first else {
    throw RepairError.message("Could not hash Node: \(trimmed(result.stderr))")
  }
  return String(hash)
}

private func checkItemExists(options: Options) throws {
  let result = try runCaptured(
    "/usr/bin/security",
    [
      "find-generic-password",
      "-a", options.account,
      "-s", options.service,
      options.keychain,
    ]
  )
  guard result.status == 0 else {
    throw RepairError.message(
      "Could not find the exact Keychain item \(options.service)/\(options.account) in \(options.keychain)"
    )
  }
}

private func openKeychain(at path: String) throws -> SecKeychain {
  var keychain: SecKeychain?
  let status = path.withCString { SecKeychainOpen($0, &keychain) }
  guard status == errSecSuccess, let keychain else {
    throw RepairError.message("SecKeychainOpen failed with status \(status): \(path)")
  }
  return keychain
}

private func findItem(options: Options, keychain: SecKeychain) throws -> SecKeychainItem {
  let query: [CFString: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: options.service,
    kSecAttrAccount: options.account,
    kSecMatchSearchList: [keychain] as CFArray,
    kSecMatchLimit: kSecMatchLimitAll,
    kSecReturnRef: true,
  ]

  var result: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &result)
  guard status == errSecSuccess, let result else {
    throw RepairError.message("SecItemCopyMatching failed with status \(status)")
  }

  let items = result as! NSArray
  guard items.count == 1 else {
    throw RepairError.message(
      "Expected exactly one matching Keychain item, found \(items.count); refusing to change an ambiguous ACL"
    )
  }
  return items[0] as! SecKeychainItem
}

private func copyAccess(for item: SecKeychainItem) throws -> SecAccess {
  var access: SecAccess?
  let status = SecKeychainItemCopyAccess(item, &access)
  guard status == errSecSuccess, let access else {
    throw RepairError.message("SecKeychainItemCopyAccess failed with status \(status)")
  }
  return access
}

private func copyACLs(from access: SecAccess) throws -> [SecACL] {
  var list: CFArray?
  let status = SecAccessCopyACLList(access, &list)
  guard status == errSecSuccess, let list else {
    throw RepairError.message("SecAccessCopyACLList failed with status \(status)")
  }
  return (list as NSArray).map { $0 as! SecACL }
}

private func authorizes(_ name: String, acl: SecACL) -> Bool {
  let authorizations = SecACLCopyAuthorizations(acl) as NSArray
  return authorizations.contains { String(describing: $0) == name }
}

private func copyContents(
  of acl: SecACL
) throws -> (applications: NSArray?, description: String, selector: SecKeychainPromptSelector) {
  var applications: CFArray?
  var description: CFString?
  var selector = SecKeychainPromptSelector()
  let status = SecACLCopyContents(acl, &applications, &description, &selector)
  guard status == errSecSuccess, let description else {
    throw RepairError.message("SecACLCopyContents failed with status \(status)")
  }
  return (applications as NSArray?, description as String, selector)
}

private func trustedApplicationPath(_ value: Any) -> String? {
  var data: CFData?
  let status = SecTrustedApplicationCopyData(value as! SecTrustedApplication, &data)
  guard status == errSecSuccess, let data else { return nil }
  return String(data: data as Data, encoding: .utf8)?
    .trimmingCharacters(in: .controlCharacters)
}

private func decodeHex(_ value: String) -> Data? {
  guard value.count.isMultiple(of: 2) else { return nil }
  var data = Data(capacity: value.count / 2)
  var index = value.startIndex
  while index < value.endIndex {
    let next = value.index(index, offsetBy: 2)
    guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
    data.append(byte)
    index = next
  }
  return data
}

private func decodePartitions(from description: String) throws -> [String] {
  let data: Data
  if description.hasPrefix("<?xml") || description.hasPrefix("bplist") {
    data = Data(description.utf8)
  } else if let decoded = decodeHex(description) {
    data = decoded
  } else {
    throw RepairError.message("Could not decode the partition ACL description")
  }

  guard
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
    let partitions = plist["Partitions"] as? [String]
  else {
    throw RepairError.message("The partition ACL has no string-array Partitions value")
  }
  guard partitions.allSatisfy({ !$0.contains(",") && !$0.contains("\n") }) else {
    throw RepairError.message("The partition ACL contains an unsafe partition value")
  }
  return partitions
}

private struct ACLState {
  let hasTrustedNode: Bool
  let partitions: [String]
}

private func inspectACL(item: SecKeychainItem, nodePath: String) throws -> ACLState {
  let access = try copyAccess(for: item)
  let acls = try copyACLs(from: access)
  let decryptACLs = acls.filter { authorizes("ACLAuthorizationDecrypt", acl: $0) }
  guard !decryptACLs.isEmpty else {
    throw RepairError.message("No decrypt ACL was found; refusing to replace the item's ACL structure")
  }

  var hasTrustedNode = false
  for acl in decryptACLs {
    let contents = try copyContents(of: acl)
    if contents.applications == nil {
      hasTrustedNode = true
      continue
    }
    if contents.applications!.contains(where: { trustedApplicationPath($0) == nodePath }) {
      hasTrustedNode = true
    }
  }

  let partitionACLs = acls.filter { authorizes("ACLAuthorizationPartitionID", acl: $0) }
  guard partitionACLs.count == 1 else {
    throw RepairError.message(
      "Expected exactly one partition ACL, found \(partitionACLs.count); refusing an ambiguous replacement"
    )
  }
  let partitions = try decodePartitions(from: copyContents(of: partitionACLs[0]).description)
  return ACLState(hasTrustedNode: hasTrustedNode, partitions: partitions)
}

private func addTrustedNode(
  item: SecKeychainItem,
  nodePath: String,
  dryRun: Bool
) throws -> Bool {
  let access = try copyAccess(for: item)
  let acls = try copyACLs(from: access)
  let decryptACLs = acls.filter { authorizes("ACLAuthorizationDecrypt", acl: $0) }
  guard !decryptACLs.isEmpty else {
    throw RepairError.message("No decrypt ACL was found")
  }

  var trustedNode: SecTrustedApplication?
  let trustedStatus = nodePath.withCString {
    SecTrustedApplicationCreateFromPath($0, &trustedNode)
  }
  guard trustedStatus == errSecSuccess, let trustedNode else {
    throw RepairError.message(
      "SecTrustedApplicationCreateFromPath failed with status \(trustedStatus)"
    )
  }

  var changed = false
  for acl in decryptACLs {
    let contents = try copyContents(of: acl)
    guard let applications = contents.applications else {
      print("Decrypt ACL already permits all applications; leaving it unchanged")
      continue
    }
    if applications.contains(where: { trustedApplicationPath($0) == nodePath }) {
      continue
    }

    print("Trusted-application ACL needs Node: \(nodePath)")
    if !dryRun {
      let updated = applications.mutableCopy() as! NSMutableArray
      updated.add(trustedNode)
      let status = SecACLSetContents(
        acl,
        updated as CFArray,
        contents.description as CFString,
        contents.selector
      )
      guard status == errSecSuccess else {
        throw RepairError.message("SecACLSetContents failed with status \(status)")
      }
    }
    changed = true
  }

  if changed && !dryRun {
    print("macOS may ask permission to change the existing Copilot item ACL.")
    let status = SecKeychainItemSetAccess(item, access)
    guard status == errSecSuccess else {
      throw RepairError.message("SecKeychainItemSetAccess failed with status \(status)")
    }
    print("Added Node to the decrypt ACL without reading or changing the stored secret")
  }
  return changed
}

private func setPartitionsIfNeeded(
  options: Options,
  existing: [String],
  teamPartition: String
) throws -> Bool {
  guard !existing.contains(teamPartition) else { return false }

  let updated = existing + [teamPartition]
  print("Partition ACL needs \(teamPartition)")
  if options.dryRun { return true }

  print("Enter the login Keychain password at the secure prompt from /usr/bin/security.")
  try runInteractive(
    "/usr/bin/security",
    [
      "set-generic-password-partition-list",
      "-a", options.account,
      "-s", options.service,
      "-S", updated.joined(separator: ","),
      options.keychain,
    ]
  )
  print("Added \(teamPartition) while preserving \(existing.count) existing partition entries")
  return true
}

private func main() throws {
  guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 10 else {
    throw RepairError.message("This script requires macOS")
  }

  let options = try parseOptions()
  let nodePath = try discoverNode(command: options.nodeCommand)
  let hashBefore = try sha256(at: nodePath)
  let teamID = try verifySignedNode(at: nodePath)
  let teamPartition = "teamid:\(teamID)"

  print("Node: \(nodePath)")
  print("SHA-256: \(hashBefore)")
  print("Existing signed identity: \(teamPartition)")
  print("Keychain item: \(options.service)/\(options.account)")
  if options.dryRun { print("Dry run: no ACL changes will be made") }

  try checkItemExists(options: options)
  let keychain = try openKeychain(at: options.keychain)
  var item = try findItem(options: options, keychain: keychain)
  let initial = try inspectACL(item: item, nodePath: nodePath)

  let trustedChanged = try addTrustedNode(
    item: item,
    nodePath: nodePath,
    dryRun: options.dryRun
  )
  let partitionChanged = try setPartitionsIfNeeded(
    options: options,
    existing: initial.partitions,
    teamPartition: teamPartition
  )

  if options.dryRun {
    if !trustedChanged && !partitionChanged {
      print("ACL is already correct")
    }
    return
  }

  item = try findItem(options: options, keychain: keychain)
  let final = try inspectACL(item: item, nodePath: nodePath)
  guard final.hasTrustedNode else {
    throw RepairError.message("Verification failed: Node is absent from the decrypt ACL")
  }
  guard final.partitions.contains(teamPartition) else {
    throw RepairError.message("Verification failed: \(teamPartition) is absent from the partition ACL")
  }

  let hashAfter = try sha256(at: nodePath)
  guard hashAfter == hashBefore else {
    throw RepairError.message("Node changed while the ACL was being updated")
  }
  _ = try verifySignedNode(at: nodePath)

  if !trustedChanged && !partitionChanged {
    print("ACL was already correct; no changes were made")
  } else {
    print("Copilot Keychain ACL repair verified")
  }
  print("Node was not modified or re-signed")
}

do {
  try main()
} catch {
  fputs("error: \(error)\n", stderr)
  exit(1)
}
