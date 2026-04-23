# awesome-claude-tricks

A collection of tips, tricks, and scripts for getting more out of [Claude](https://claude.ai) and [Claude Code](https://claude.ai/code).

Each folder is a self-contained tip. Browse to what interests you, or read on for a quick overview.

## Contents

### [WSL2/](./WSL2/)

**Give Claude Code direct access to Docker logs on Windows.**

Claude Code runs on Windows but Docker lives inside WSL2 — which means Claude can't read container logs without your help. This tip wires up a passwordless SSH tunnel from Windows into your WSL2 distro so Claude can run `docker compose logs` and `docker ps` on its own.

| File | Purpose |
|------|---------|
| `setup-claude-wsl2-ssh.ps1` | One-shot PowerShell script that installs and configures everything |
| `CLAUDE.md` | Drop this into your project's `CLAUDE.md` to tell Claude how to use the tunnel |

**Quick start:**
```powershell
.\WSL2\setup-claude-wsl2-ssh.ps1
```

---

## Contributing

If you have a trick worth sharing, open a PR. Keep each tip in its own folder with a brief explanation of the problem it solves.
