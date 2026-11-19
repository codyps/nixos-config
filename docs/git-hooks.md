# Global Git hooks

Home Manager configures a global `pre-commit` hook for staged changes and a
`commit-msg` hook for commit messages. The message hook rejects Claude
`Co-authored-by` lines by default, including variant display names using
`noreply@anthropic.com`.

To opt in as a repository policy, include the exact standalone line
`Please include Claude co-author trailers.` in a root `AGENTS.md`, `CLAUDE.md`,
or `README*` file, or a Markdown file under `docs/`. The hook reads the Git
index, so the file and the request must be staged or already committed.

For a local override in one repository, run
`git config --local hooks.allowClaudeCoAuthor true`. Remove the override with
`git config --local --unset hooks.allowClaudeCoAuthor`.

For a single commit, run `GIT_ALLOW_CLAUDE_COAUTHOR=1 git commit` with your
usual options. The em-dash checks still apply.

The em-dash checks continue to use `GIT_ALLOW_EMDASH=1` as their own bypass.
A repository with its own `core.hooksPath` uses that directory for its hooks.

The Nix-installed `gh` also checks GitHub pull request descriptions. Run from
the target checkout and provide the final text explicitly, for example
`gh pr create --title "Fix the parser" --body-file pr.md` or
`gh pr edit 123 --body-file pr.md`. Inline `--body` and stdin via
`--body-file -` also work. The same documentation opt-in, repository setting,
and `GIT_ALLOW_CLAUDE_COAUTHOR=1` override apply.

For creation and body edits, supply the complete description before invoking
`gh`. The wrapper disables prompts and rejects options that generate or edit
the body, such as `--fill`, `--editor`, `--recover`, and `--web`. Other `gh`
commands pass through to the original binary.

`gh-unwrapped` runs the original GitHub CLI directly, including its interactive
prompts and description-generation options.
