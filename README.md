# hng13-stage1

# 🚀 Automated Docker Deployment Script - Flask web app for HNG 13 Stage 1 task

A robust Bash script to **automate end-to-end deployment** of Dockerized applications on a remote Linux server via SSH.  
It handles everything from cloning your Git repository to setting up Docker, Docker Compose, and Nginx reverse proxy for production-ready deployment.

---

## 🧩 Features

- 🔐 Secure SSH-based remote deployment  
- 🐳 Automatic Docker & Docker Compose setup  
- 🌐 Nginx reverse proxy configuration  
- 🔁 Git clone or update with branch selection  
- ✅ Health checks and deployment validation  
- 🧹 Cleanup mode for safe rollback  
- 📜 Detailed logging with timestamps  

---

## ⚙️ Requirements

- Local system with:
  - `bash`, `git`, `ssh`, `scp`, `rsync`, `curl`
- Remote Linux server (Ubuntu/Debian recommended)
- Docker and Docker Compose (installed automatically if missing)
- Nginx (auto-installed and configured)
- Git repository containing:
  - `Dockerfile` **or**
  - `docker-compose.yml`

---