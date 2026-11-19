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
