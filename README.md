# HNG13-stage-1-DevOps

# Automated deployment script (Stage 1 - DevOps Intern)

Usage:
1. Save `deploy.sh` locally and make executable:
   chmod +x deploy.sh

2. Run:
   ./deploy.sh

The script will ask for:
- Git repo URL
- Personal Access Token (if repo is private)
- Branch (default: main)
- Remote SSH username
- Remote server IP
- SSH key path
- Application internal port

To cleanup:
  ./deploy.sh --cleanup

Logs are stored locally under ./logs/deploy_YYYYMMDD_HHMMSS.log
