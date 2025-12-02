#!/bin/bash
# Backend startup script for macapy.io
# This script activates the Python venv and starts the FastAPI server

set -e

# Get the project root directory (parent of scripts/)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_ROOT"

# Load environment variables from .env if it exists
if [ -f .env ]; then
    # Filter out comments (lines starting with #) and strip inline comments
    set -a
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip empty lines and lines starting with #
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Strip inline comments and leading/trailing whitespace
        line=$(echo "$line" | sed 's/[[:space:]]*#.*$//' | xargs)
        # Only export if line contains =
        [[ "$line" == *"="* ]] && export "$line"
    done < .env
    set +a
fi

# Set default environment variables if not already set
export DATABASE_URL="${DATABASE_URL:-postgresql+asyncpg://hoangngo@localhost:5432/macapy_db}"
export ALLOWED_ORIGINS="${ALLOWED_ORIGINS:-http://localhost:3000,http://127.0.0.1:3000,http://localhost:5173,http://127.0.0.1:5173}"

# Activate virtual environment
if [ -f ".venv/bin/activate" ]; then
    source .venv/bin/activate
elif [ -f "venv/bin/activate" ]; then
    source venv/bin/activate
else
    echo "Error: No Python virtual environment found. Please create one with:"
    echo "  python -m venv .venv"
    echo "  source .venv/bin/activate"
    echo "  pip install -r backend/requirements.txt"
    exit 1
fi

echo "Starting backend server at http://localhost:8000..."
echo "API docs available at http://localhost:8000/docs"

# Start uvicorn with hot reload
cd backend
exec uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
