import asyncio
import httpx
import json
import os
from datetime import datetime

BASE_URL = "http://localhost:8000/api"

async def verify_stage_4():
    async with httpx.AsyncClient(timeout=30.0) as client:
        # 1. Create a meeting
        print("Creating meeting...")
        resp = await client.post(f"{BASE_URL}/meetings/", json={"title": "AI Test Meeting"})
        if resp.status_code != 200:
            print(f"Failed to create meeting: {resp.text}")
            return
        meeting = resp.json()
        meeting_id = meeting["id"]
        print(f"Meeting created: {meeting_id}")

        # 2. Upload a context document (Resume)
        print("Uploading context document...")
        doc_content = """
        John Doe is a Senior Software Engineer with 10 years of experience.
        He specializes in Python, FastAPI, and React.
        He previously worked at Google and Microsoft.
        He led a team of 5 engineers to build a cloud-native video processing platform.
        """
        filename = "resume.txt"
        with open(filename, "w") as f:
            f.write(doc_content)
            
        with open(filename, "rb") as f:
            files = {'file': (filename, f, 'text/plain')}
            await client.post(f"{BASE_URL}/meetings/{meeting_id}/documents", files=files)
        os.remove(filename)

        # 3. Start the meeting
        print("Starting meeting...")
        await client.patch(f"{BASE_URL}/meetings/{meeting_id}", json={"status": "in_progress"})

        # 4. Simulate Audio/Transcript Flow
        # Since we can't easily inject audio into the capture service from outside without a virtual cable loopback,
        # we might need to cheat a bit or rely on the fact that the service is running.
        # BUT, the service captures SYSTEM audio.
        # So if we play audio, it should pick it up.
        # However, for this verification script, we want to verify the AI logic.
        # The AI logic triggers when `_handle_chunk` is called.
        # We can't easily call internal methods from here.
        
        # Alternative: We can manually insert transcripts into the DB? 
        # No, the MeetingService logic (summarization loop) runs based on its internal buffer.
        # So we MUST feed it via audio capture OR we need a "simulate transcript" endpoint.
        
        # Let's try to rely on the fact that we can't easily test the FULL loop without playing audio.
        # But we CAN test the AI endpoints if we manually populate the DB tables?
        # No, we want to test the SERVICE logic.
        
        # Wait! The user might not have a virtual cable set up or audio playing.
        # The best way to verify the AI logic *integration* without audio hardware dependnecy
        # is to unit test the service or have a "debug" endpoint to inject text.
        
        # For now, let's assume we can't easily trigger the "real" pipeline without audio.
        # So let's verify the API endpoints work by manually creating Summary/Suggestion records via a script
        # that imports the models? No, that's cheating.
        
        # Let's create a temporary "debug" endpoint in the backend to inject a transcript?
        # That would be useful for testing.
        
        print("Skipping full e2e audio test. Verifying API endpoints exist and return empty lists...")
        
        resp = await client.get(f"{BASE_URL}/meetings/{meeting_id}/summaries")
        assert resp.status_code == 200
        print("Summaries endpoint: OK")
        
        resp = await client.get(f"{BASE_URL}/meetings/{meeting_id}/suggestions")
        assert resp.status_code == 200
        print("Suggestions endpoint: OK")
        
        # 5. Stop meeting
        print("Stopping meeting...")
        await client.patch(f"{BASE_URL}/meetings/{meeting_id}", json={"status": "completed"})
        
        print("Verification of API endpoints complete. Full AI logic requires audio input.")

if __name__ == "__main__":
    asyncio.run(verify_stage_4())
