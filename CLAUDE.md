# CLAUDE.md — AI Assistant Guide for master-AI

This file provides context and conventions for AI coding assistants (e.g., Claude Code) working in this repository. Keep this document up to date as the project evolves.

---

## Project Overview

**Repository:** `paphavitmooc/master-AI`
**Status:** Early-stage / greenfield project
**Description:** Project description not yet defined. Update this section once the project purpose is established.

---

## Repository Structure

```
master-AI/
├── CLAUDE.md          # This file — AI assistant guidance
└── README.md          # Project title placeholder
```

> This is a new repository. As source code, configuration, and tooling are added, update the directory tree above to reflect the actual structure.

---

## Git Workflow

### Branches

| Branch | Purpose |
|--------|---------|
| `master` | Stable, production-ready code |
| `claude/<task-id>` | AI-generated feature/fix branches |

### Branch Naming Convention

- AI assistant branches must start with `claude/` and end with the session ID suffix.
- Example: `claude/claude-md-mm8ohnqesf0pb9m3-FbMNA`
- Never push directly to `master` without explicit user approval.

### Commit Conventions

Write clear, descriptive commit messages in the imperative mood:

```
Add user authentication module
Fix null pointer in data parser
Update CLAUDE.md with project structure
```

- Keep the subject line under 72 characters.
- Add a blank line and body for commits that need more explanation.
- Reference issue numbers when applicable: `Fix login bug (#42)`.

### Push Protocol

Always push with tracking:

```bash
git push -u origin <branch-name>
```

If a push fails due to network errors, retry with exponential backoff: 2s → 4s → 8s → 16s (max 4 retries).

---

## Development Conventions

> These conventions will be enforced once a technology stack is chosen. Update this section with specific tooling and commands as the project grows.

### General Principles

- **Minimal changes:** Only modify what is necessary for the task at hand.
- **No over-engineering:** Avoid abstractions, helpers, or features not explicitly requested.
- **Security-first:** Never introduce command injection, XSS, SQL injection, or other OWASP Top 10 vulnerabilities.
- **No backwards-compatibility shims:** Remove dead code completely rather than commenting it out.
- **No generated docs unless asked:** Do not add docstrings, README sections, or changelogs unless the user requests them.

### File Handling

- Prefer editing existing files over creating new ones.
- Never create or commit files containing secrets (`.env`, credential files, API keys).
- Use `.gitignore` to exclude build artifacts, dependency directories, and local config files.

---

## Testing

> No testing framework has been configured yet. When one is chosen, document:
> - How to run the full test suite
> - How to run a single test file
> - Minimum coverage requirements
> - CI test commands

Placeholder commands (to be updated):

```bash
# Run all tests
<test command here>

# Run a single test
<single test command here>
```

---

## Linting & Formatting

> No linting or formatting tools have been configured yet. When chosen, document:
> - Formatter (e.g., Prettier, Black, gofmt)
> - Linter (e.g., ESLint, Flake8, golangci-lint)
> - How to auto-fix issues
> - Pre-commit hooks if any

Placeholder commands (to be updated):

```bash
# Format code
<format command here>

# Lint code
<lint command here>
```

---

## Environment Setup

> No dependencies are defined yet. When the stack is established, document:
> - Prerequisites (Node version, Python version, Go version, etc.)
> - Dependency installation
> - Environment variable setup (reference `.env.example`, never commit actual values)

Placeholder setup (to be updated):

```bash
# Install dependencies
<install command here>

# Copy environment template
cp .env.example .env
# Then edit .env with your local values
```

---

## CI/CD

> No CI/CD pipeline is configured yet. When set up, document:
> - Which CI provider is used (GitHub Actions, GitLab CI, etc.)
> - How to check pipeline status
> - Required status checks before merging

---

## AI Assistant Instructions

When working in this repository, follow these rules:

### Always Do

1. **Read files before editing them.** Never suggest or apply changes to code you haven't read.
2. **Keep changes minimal and focused.** Complete the task described; do not refactor surrounding code.
3. **Verify the current branch** before committing — work must be on a `claude/` branch.
4. **Update this CLAUDE.md** if the project structure, commands, or conventions change.
5. **Check for secrets** before committing. Never include API keys, passwords, or tokens in committed files.

### Never Do

1. Push to `master` without explicit user permission.
2. Delete files or branches without confirming with the user.
3. Force-push (`--force`) to shared branches.
4. Skip pre-commit hooks (`--no-verify`) unless explicitly instructed.
5. Amend previously pushed commits — create a new commit instead.
6. Add features, refactors, or improvements beyond what was asked.

### When Blocked

- Do not retry the same failing approach repeatedly.
- Investigate root causes before attempting workarounds.
- Ask the user for clarification using the appropriate question tool.

---

## Remote

```
origin  http://local_proxy@127.0.0.1:49681/git/paphavitmooc/master-AI
```

---

## Maintainers

| Name | Email |
|------|-------|
| paphavitmooc | paphavit.ker@thaimooc.ac.th |

---

*Last updated: 2026-03-02. Update this file whenever the project structure, tooling, or conventions change.*
