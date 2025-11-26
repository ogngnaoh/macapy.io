import asyncio
import httpx
import sys
import os

# Add backend directory to python path
sys.path.append(os.path.join(os.path.dirname(__file__), ".."))

from app.config import settings

BASE_URL = f"http://localhost:{settings.BACKEND_PORT}/api"

async def verify_stage_2_4():
    async with httpx.AsyncClient(base_url=BASE_URL) as client:
        print("1. Creating a meeting...")
        response = await client.post("/meetings/", json={"title": "Test Meeting", "platform": "test"})
        if response.status_code != 200:
            print(f"Failed to create meeting: {response.text}")
            return
        meeting = response.json()
        meeting_id = meeting["id"]
        print(f"   Meeting created: {meeting_id}")

        print("\n2. Creating a transcript...")
        transcript_data = {
            "meeting_id": meeting_id,
            "text": "Hello world",
            "timestamp": 1.5,
            "speaker": "User"
        }
        response = await client.post("/transcripts/", json=transcript_data)
        if response.status_code != 200:
            print(f"Failed to create transcript: {response.text}")
            return
        transcript = response.json()
        transcript_id = transcript["id"]
        print(f"   Transcript created: {transcript_id}")

        print("\n3. Retrieving transcript...")
        response = await client.get(f"/transcripts/{transcript_id}")
        if response.status_code != 200:
            print(f"Failed to get transcript: {response.text}")
            return
        print("   Transcript retrieved successfully")

        print("\n4. Deleting meeting (should cascade delete transcript)...")
        response = await client.delete(f"/meetings/{meeting_id}")
        if response.status_code != 200:
            print(f"Failed to delete meeting: {response.text}")
            return
        print("   Meeting deleted")

        print("\n5. Verifying transcript is gone...")
        response = await client.get(f"/transcripts/{transcript_id}")
        if response.status_code == 404:
            print("   Success: Transcript not found (as expected)")
        else:
            print(f"   Failure: Transcript still exists or other error: {response.status_code}")

if __name__ == "__main__":
    # Ensure server is running before running this script
    print("Make sure the backend server is running on localhost:8000")
    asyncio.run(verify_stage_2_4())
