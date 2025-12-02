# Workspace Scripts

Shared automation scripts for the monorepo workspace.

## Available Scripts

- `start-backend.sh`: Start the FastAPI backend server (used by npm scripts)

## Usage

These scripts are typically invoked via npm workspace commands:

```bash
npm run dev            # Start both backend and frontend
npm run dev:backend    # Start backend only (uses start-backend.sh)
```

## Adding New Scripts

Place scripts here that:
- Are used across multiple packages (backend/frontend)
- Are invoked via npm workspace commands
- Handle deployment, CI/CD, or workspace-wide tasks

For package-specific scripts:
- Backend scripts go in `backend/scripts/`
- Frontend scripts go in `frontend/scripts/` (if needed)
