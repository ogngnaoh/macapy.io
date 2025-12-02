import asyncio
import sys
from pathlib import Path
from sqlalchemy import text

# Add backend to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.db.session import get_db

async def inspect_db():
    print("Inspecting DB...")
    async for session in get_db():
        try:
            result = await session.execute(text("SELECT table_name FROM information_schema.tables WHERE table_schema = 'public'"))
            tables = result.fetchall()
            print("Tables found:", tables)
        except Exception as e:
            print(f"Error: {e}")

if __name__ == "__main__":
    asyncio.run(inspect_db())
