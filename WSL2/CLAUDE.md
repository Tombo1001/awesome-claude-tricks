\# Claude Code Global Config



\## Docker / WSL2 Environment



\- Docker and Docker Compose run inside WSL2 Ubuntu, not on Windows directly.

\- SSH access to WSL2 is available via `ssh wsl2` — use this for all Docker operations.

\- Always check container logs proactively. Do not ask me to paste them.



\### Useful commands



&#x20;   # All service logs (replace YOUR\_PROJECT with your actual path inside WSL2)

&#x20;   ssh wsl2 "docker compose -f \~/YOUR\_PROJECT/docker-compose.yml logs --tail=100"



&#x20;   # Single service

&#x20;   ssh wsl2 "docker compose -f \~/YOUR\_PROJECT/docker-compose.yml logs --tail=100 YOUR\_SERVICE"



&#x20;   # Container status

&#x20;   ssh wsl2 "docker ps -a"



&#x20;   # Restart a service

&#x20;   ssh wsl2 "docker compose -f \~/YOUR\_PROJECT/docker-compose.yml restart YOUR\_SERVICE"



\## General Preferences



\- I run Windows 11 with WSL2 Ubuntu for Docker and Node workloads.

\- Prefer Ubuntu/WSL2 for testing and deploying containers and npm projects.

\- I run Hugo for my blog. Use `hugo server -D` to preview before committing.

