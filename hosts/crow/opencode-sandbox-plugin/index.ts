// OpenCode plugin: execute agent tools inside the crow-ai container.
//
// This plugin is NOT loaded from the managed system configuration. It is
// installed per project by `sys opencode-sandbox-enable <dir>`, which
// writes a plugins entry into <dir>/.opencode/opencode.json. Only sessions
// anchored inside such a project load it; `sys opencode-sandbox-disable`
// removes the entry and OpenCode hot-reloads it away. Projects that never
// enable it are completely unaffected.
//
// In an enabled project, the session's shell runs as cody-ai@10.80.0.2
// over SSH: the shell create.before hook rewrites its command, keeping the
// native executor's output handling, timeouts, and background semantics
// completely intact. This OpenCode release validates tool results against
// per-tool native output schemas that replaced executors cannot satisfy,
// so the filesystem tools (read, write, edit, glob, grep, and the patch
// and worktree create/remove tools) are removed in enabled projects
// instead; the model performs file operations through the sandboxed
// shell. The SSH-backed implementations below are ready to return once
// per-tool output schemas can be declared or discovered.
//
// The OpenCode server itself (sessions, provider traffic, managed
// settings, secrets) always stays on the host. When the container is
// unreachable, sandboxed tools fail closed rather than executing on the
// host. Host session directories map onto the container's workspace root
// (/home/cody/<project> becomes /home/cody-ai/workspaces/<project>); the
// shell creates the mapped directory on first use.
//
// Tool definitions are dumped to /var/lib/opencode/sandbox-definitions.json
// on load so executor return shapes can be checked against the native
// tools' declared output schemas.

import { spawn } from "node:child_process"
import { appendFileSync, existsSync, writeFileSync } from "node:fs"

// Options are baked in when Nix builds the plugin (@@SANDBOX_OPTIONS_JSON@@
// below is replaced with a JSON literal) and merged with any ctx.options a
// newer OpenCode may pass from the project config entry.
const bakedOptions: Partial<Options> = JSON.parse("@@SANDBOX_OPTIONS_JSON@@")

interface Options {
  sshBinary: string
  host: string
  user: string
  keyFile: string
  knownHostsFile: string
  defaultTimeoutMs?: number
  mappings?: { host: string; guest: string }[]
}

interface SshResult {
  code: number
  out: string
  err: string
}

// Removed in enabled projects: they execute on the host, and this OpenCode
// release rejects replaced executors' results against their native output
// schemas. File work goes through the sandboxed shell instead.
const REMOVED_TOOLS = [
  "read", "write", "edit", "glob", "grep", "list", "bash",
  "patch", "opencode_worktree_create", "opencode_worktree_remove",
]
const DEFINITIONS_DUMP = "/var/lib/opencode/sandbox-definitions.json"

// Quote a value for the remote POSIX shell. Never throws, even when a
// caller passes a missing option or field.
const shq = (value: unknown): string => `'${String(value ?? "").replaceAll("'", `'\\''`)}'`

const toNumber = (value: unknown): number | undefined => {
  const n = typeof value === "number" ? value : typeof value === "string" ? Number(value) : NaN
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : undefined
}

// Minimal glob conversion: "**" crosses directory separators, "*" and "?"
// do not, and one level of "{a,b}" alternatives is expanded.
const globToRegexps = (pattern: string): RegExp[] => {
  const variants: string[] = [pattern]
  for (let i = 0; i < variants.length && variants.length <= 32; i++) {
    const candidate = variants[i]!
    const brace = candidate.match(/\{([^{}]*,[^{}]*)\}/)
    if (!brace || brace.index === undefined) continue
    const expanded = brace[1]!.split(",").map((part) => candidate.slice(0, brace.index!) + part + candidate.slice(brace.index! + brace[0].length))
    variants.splice(i, 1, ...expanded)
    i = -1
  }
  return variants.slice(0, 32).map((variant) => {
    let source = ""
    for (let j = 0; j < variant.length; j++) {
      const char = variant[j]!
      if (char === "*") {
        let stars = 0
        while (variant[j] === "*") {
          stars++
          j++
        }
        j--
        source += stars >= 2 ? ".*" : "[^/]*"
      } else if (char === "?") {
        source += "[^/]"
      } else {
        source += char.replace(/[.*+^${}()|[\]\\]/g, "\\$&")
      }
    }
    return new RegExp(`^${source}$`)
  })
}

export default {
  id: "crow-sandbox",
  async setup(ctx: any) {
    // Merge runtime options over the baked ones, but drop empty-string and
    // null/undefined placeholders: this release populates ctx.options with
    // empty values for entries that carry no options.
    const runtime = (ctx.options ?? {}) as Record<string, unknown>
    const opts = { ...bakedOptions } as Options
    for (const key of Object.keys(runtime)) {
      const value = runtime[key]
      if (value === undefined || value === null) continue
      if (typeof value === "string" && value.trim() === "") continue
      ;(opts as Record<string, unknown>)[key] = value
    }
    const mappings = (opts.mappings ?? []).filter((m) => m && m.host && m.guest)
    const defaultTimeoutMs = toNumber(opts.defaultTimeoutMs) ?? 120_000
    const userHost = `${opts.user}@${opts.host}`

    // Translate host session paths onto the container workspace. Absolute
    // container paths (what tools report) pass through unchanged.
    function translatePath(raw: unknown): string {
      let path = typeof raw === "string" ? raw.trim() : ""
      if (!path.startsWith("/")) {
        const base = mappings[0]?.guest ?? "/"
        path = `${base}${path ? `/${path}` : ""}`
      }
      for (const m of mappings) {
        if (path === m.host) return m.guest
        if (path.startsWith(`${m.host}/`)) return m.guest + path.slice(m.host.length)
      }
      return path
    }

    const defaultCwd = translatePath(typeof ctx.location?.directory === "string" ? ctx.location.directory : "")

    function runSsh(remote: string, input?: { stdin?: string; timeoutMs?: number; signal?: AbortSignal }): Promise<SshResult> {
      return new Promise((resolve) => {
        let child: ReturnType<typeof spawn>
        try {
          child = spawn(opts.sshBinary, [
            "-F", "/dev/null",
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", `UserKnownHostsFile=${opts.knownHostsFile}`,
            "-o", "ConnectTimeout=10",
            "-i", opts.keyFile,
            userHost,
            "--", remote,
          ], { stdio: ["pipe", "pipe", "pipe"] })
        } catch (error) {
          resolve({ code: -1, out: "", err: String(error) })
          return
        }
        let out = ""
        let err = ""
        let settled = false
        let timer: ReturnType<typeof setTimeout> | undefined
        let onAbort: (() => void) | undefined
        const finish = (code: number) => {
          if (settled) return
          settled = true
          if (timer) clearTimeout(timer)
          if (onAbort && input?.signal) input.signal.removeEventListener("abort", onAbort)
          resolve({ code, out, err })
        }
        timer = setTimeout(() => {
          err += "\n[sandbox] command timed out"
          child.kill("SIGKILL")
        }, input?.timeoutMs ?? defaultTimeoutMs)
        onAbort = () => {
          err += "\n[sandbox] command cancelled"
          child.kill("SIGKILL")
        }
        if (input?.signal) {
          if (input.signal.aborted) onAbort()
          else input.signal.addEventListener("abort", onAbort)
        }
        child.stdout!.on("data", (data) => { out += data })
        child.stderr!.on("data", (data) => { err += data })
        child.on("error", (error) => {
          err += String(error)
          finish(-1)
        })
        child.on("close", (code) => finish(code ?? -1))
        if (input?.stdin !== undefined) child.stdin!.end(input.stdin)
        else child.stdin!.end()
      })
    }

    // Results use the documented {content} plugin-tool convention; the
    // clone below declares a matching permissive output schema so the
    // native tools' richer output shapes do not reject our returns.
    const ok = (content: string, title?: string) => (title ? { title, content } : { content })
    const fail = (content: string) => ({ title: "sandbox error", content: `[sandbox error] ${content}` })

    async function bash(input: any, context: any) {
      const command = String(input?.command ?? "")
      if (!command.trim()) return fail("No command provided.")
      const workdir = translatePath(typeof input?.workdir === "string" && input.workdir.trim() ? input.workdir : defaultCwd)
      const timeoutMs = toNumber(input?.timeout) ?? defaultTimeoutMs
      // Create the workspace on first use so a host-anchored session maps
      // onto a real directory inside the container.
      const remote =
        `cd -P ${shq(workdir)} 2>/dev/null || { mkdir -p ${shq(workdir)} && cd -P ${shq(workdir)}; } && ` +
        `bash -lc ${shq(command)}`
      const r = await runSsh(remote, { timeoutMs, signal: context?.signal })
      const output = [r.out, r.err].filter((part) => part.trim()).join("\n")
      if (r.code !== 0) return ok(`${output}\n[sandbox] exit code ${r.code}`.trim(), command.slice(0, 60))
      return ok(output.trim() || "(no output)", command.slice(0, 60))
    }

    async function read(input: any, context: any) {
      const path = translatePath(input?.path)
      const r = await runSsh(`cat -- ${shq(path)}`, { signal: context?.signal })
      if (r.code !== 0) return fail(`reading ${path}: ${r.err.trim() || `exit ${r.code}`}`)
      if (r.out.includes("\0")) {
        const size = await runSsh(`wc -c < ${shq(path)}`, { signal: context?.signal })
        return ok(`[sandbox] ${path} is a binary file (${size.out.trim() || "unknown"} bytes); binary reads are not supported here.`)
      }
      const lines = r.out.split("\n")
      if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()
      const start = Math.max(1, toNumber(input?.offset) ?? 1)
      const limit = toNumber(input?.limit) ?? lines.length - start + 1
      const end = Math.min(lines.length, start - 1 + limit)
      const body = lines.slice(start - 1, end).map((line, i) => `${start + i}: ${line}`).join("\n")
      const note = start > 1 || end < lines.length ? `\n[file has ${lines.length} lines]` : ""
      return ok(body + note, path)
    }

    async function write(input: any, context: any) {
      const path = translatePath(input?.path)
      const content = String(input?.content ?? "")
      const remote = `d=$(dirname -- ${shq(path)}) && mkdir -p -- "$d" && cat > ${shq(path)}`
      const r = await runSsh(remote, { stdin: content, signal: context?.signal })
      if (r.code !== 0) return fail(`writing ${path}: ${r.err.trim() || `exit ${r.code}`}`)
      return ok(`Wrote ${Buffer.byteLength(content, "utf8")} bytes to ${path}.`, `Wrote ${path}`)
    }

    async function edit(input: any, context: any) {
      const path = translatePath(input?.path)
      const oldString = String(input?.oldString ?? "")
      const newString = String(input?.newString ?? "")
      if (!oldString) return fail("oldString is empty.")
      if (oldString === newString) return fail("oldString and newString are identical.")
      const before = await runSsh(`cat -- ${shq(path)}`, { signal: context?.signal })
      if (before.code !== 0) return fail(`reading ${path}: ${before.err.trim() || `exit ${before.code}`}`)
      const occurrences = before.out.split(oldString).length - 1
      if (occurrences === 0) {
        return fail(`String not found in ${path}. The file may have changed; re-read it and copy the text exactly, without any line-number prefixes.`)
      }
      if (occurrences > 1) {
        return fail(`Found ${occurrences} occurrences of oldString in ${path}; add surrounding lines to make it unique.`)
      }
      const after = before.out.replace(oldString, newString)
      const written = await runSsh(`cat > ${shq(path)}`, { stdin: after, signal: context?.signal })
      if (written.code !== 0) return fail(`writing ${path}: ${written.err.trim() || `exit ${written.code}`}`)
      return ok(`Edited ${path}.`, `Edited ${path}`)
    }

    async function glob(input: any, context: any) {
      const pattern = String(input?.pattern ?? "**/*")
      const root = translatePath(input?.path ?? defaultCwd)
      const limit = toNumber(input?.limit) ?? 100
      const allowHidden = input?.hidden === true || pattern.startsWith(".") || pattern.includes("/.")
      const r = await runSsh(`find ${shq(root)} -type f -printf '%T@ %p\\n' 2>/dev/null || true`, { signal: context?.signal })
      const regexps = globToRegexps(pattern)
      const matches = r.out
        .split("\n")
        .filter((line) => line.trim() !== "")
        .map((line) => {
          const space = line.indexOf(" ")
          return { mtime: Number(line.slice(0, space)), path: line.slice(space + 1) }
        })
        .filter((entry) => Number.isFinite(entry.mtime))
        .filter((entry) => regexps.some((regexp) => regexp.test(entry.path)))
        .filter((entry) => allowHidden || !entry.path.slice(root.length).split("/").some((segment) => segment.startsWith(".")))
        .sort((a, b) => b.mtime - a.mtime)
        .slice(0, limit)
      return ok(matches.length > 0 ? matches.map((entry) => entry.path).join("\n") : "No files matched.", pattern)
    }

    async function grep(input: any, context: any) {
      const pattern = String(input?.pattern ?? "")
      if (!pattern) return fail("No pattern provided.")
      const path = translatePath(input?.path ?? defaultCwd)
      const flags = ["-r", "-I", "-n", "-s", input?.literal === true ? "-F" : "-E"]
      if (input?.caseSensitive === false) flags.push("-i")
      const limit = toNumber(input?.limit)
      let remote = `grep ${flags.map(shq).join(" ")} -e ${shq(pattern)}`
      if (typeof input?.include === "string" && input.include) remote += ` --include=${shq(input.include)}`
      remote += ` -- ${shq(path)}`
      if (limit) remote += ` | head -n ${limit}`
      const r = await runSsh(remote, { signal: context?.signal })
      if (r.code === 2) return fail(`grep: ${r.err.trim() || "bad pattern or path"}`)
      const output = r.out.trim()
      return ok(output || "No matches found.", pattern)
    }

    async function list(input: any, context: any) {
      const path = translatePath(input?.path ?? defaultCwd)
      const r = await runSsh(`ls -1A -- ${shq(path)}`, { signal: context?.signal })
      if (r.code !== 0) return fail(`listing ${path}: ${r.err.trim() || `exit ${r.code}`}`)
      return ok(r.out.trim() || "(empty directory)", path)
    }

    // Unused in this release: registered only once per-tool output schemas
    // can be declared or discovered (see the header comment).
    const executors: Record<string, (input: any, context: any) => Promise<{ content: string }>> = {
      shell: bash, bash, read, write, edit, glob, grep, list,
    }
    void executors

    // Preferred shell sandboxing: rewrite the command to ssh through the
    // shell create.before hook, keeping the native executor's output,
    // timeout, and background handling completely intact.
    let shellHooked = false
    if (ctx.shell && typeof ctx.shell.hook === "function") {
      try {
        await ctx.shell.hook("create.before", (event: any) => {
          if (typeof event?.command !== "string" || !event.command.trim()) return
          const workdir = translatePath(typeof event.cwd === "string" && event.cwd.trim() ? event.cwd : "")
          const remote =
            `cd -P ${shq(workdir)} 2>/dev/null || { mkdir -p ${shq(workdir)} && cd -P ${shq(workdir)}; } && ` +
            `bash -lc ${shq(event.command)}`
          // The paths, user, and host are Nix-rendered and contain no
          // spaces or quotes; bare words avoid quoting being mangled by
          // the shell tool's own command wrapper.
          event.command =
            `${opts.sshBinary} -F /dev/null -o BatchMode=yes -o IdentitiesOnly=yes ` +
            `-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${opts.knownHostsFile} ` +
            `-o ConnectTimeout=10 -i ${opts.keyFile} ${userHost} -- ${shq(remote)}`
          try {
            appendFileSync(DEFINITIONS_DUMP, `\n[hook] ${event.command}\n`)
          } catch { /* diagnostics only */ }
        })
        shellHooked = true
        console.log("[opencode-sandbox] shell sandboxed via create.before hook")
      } catch (error) {
        console.warn(`[opencode-sandbox] shell hook unavailable (${String(error)}); falling back to tool replacement`)
      }
    }

    await ctx.tool.transform((editor: any) => {
      const dump: Record<string, any> = {}
      const dumpTool = (name: string, original: any) => {
        dump[name] = {
          keys: Object.keys(original),
          input: original.input ?? null,
          output: original.output ?? null,
          options: original.options ?? null,
        }
      }

      if (!shellHooked) {
        // Fail closed: without the hook there is no schema-safe way to
        // sandbox the shell, so it must not run on the host either.
        const shellTool = typeof editor.get === "function" ? editor.get("shell") : undefined
        if (shellTool) {
          dumpTool("shell", shellTool)
          console.warn('[opencode-sandbox] shell hook unavailable; removing the shell tool rather than running it on the host')
          editor.remove("shell")
        }
      }
      for (const name of REMOVED_TOOLS) {
        const original = typeof editor.get === "function" ? editor.get(name) : undefined
        if (!original) continue
        dumpTool(name, original)
        console.warn(`[opencode-sandbox] removing host-side tool "${name}"; file work goes through the sandboxed shell`)
        editor.remove(name)
      }

      try {
        writeFileSync(
          DEFINITIONS_DUMP,
          JSON.stringify({ at: new Date().toISOString(), shellHooked, ctxKeys: Object.keys(ctx) }, null, 2) +
            "\n" +
            JSON.stringify(dump, null, 2) +
            "\n",
        )
      } catch (error) {
        console.warn(`[opencode-sandbox] definition dump failed: ${String(error)}`)
      }
    })

    try {
      const tools = await ctx.tool.list()
      console.log(`[opencode-sandbox] sandbox ready via ${userHost} (shell hook: ${shellHooked}); effective tools: ${tools.map((tool: any) => tool.id).join(", ")}`)
    } catch {
      console.log(`[opencode-sandbox] sandbox ready via ${userHost} (shell hook: ${shellHooked})`)
    }

    return () => {
      console.log("[opencode-sandbox] unloaded")
    }
  },
}
