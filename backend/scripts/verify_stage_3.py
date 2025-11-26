import asyncio
import httpx
import os

BASE_URL = "http://localhost:8000/api"

async def verify_stage_3():
    async with httpx.AsyncClient() as client:
        # 1. Create a meeting
        print("Creating meeting...")
        resp = await client.post(f"{BASE_URL}/meetings/", json={"title": "Test Meeting"})
        if resp.status_code != 200:
            print(f"Failed to create meeting: {resp.text}")
            return
        meeting = resp.json()
        meeting_id = meeting["id"]
        print(f"Meeting created: {meeting_id}")

        # 2. Create a dummy file
        filename = "test_doc.txt"
        with open(filename, "w") as f:
            f.write("This is a test document for context retrieval. The secret code is 12345.")

        # 3. Upload document
        print("Uploading document...")
        with open(filename, "rb") as f:
            files = {'file': (filename, f, 'text/plain')}
            resp = await client.post(f"{BASE_URL}/meetings/{meeting_id}/documents", files=files)
            if resp.status_code != 200:
                print(f"Failed to upload document: {resp.text}")
                return
            doc = resp.json()
            print(f"Document uploaded: {doc['id']}")

        # 4. List documents
        print("Listing documents...")
        resp = await client.get(f"{BASE_URL}/meetings/{meeting_id}/documents")
        docs = resp.json()
        print(f"Documents found: {len(docs)}")
        assert len(docs) > 0

        # 5. Retrieve context (Manual check via DB or if we had an endpoint)
        upload_path = f"backend/uploads/{meeting_id}/{filename}"
        # Note: The server runs in backend/ so uploads are relative to that.
        # But I am running this script from root.
        # The server code says UPLOAD_DIR = "uploads".
        # If server is running in backend/, then uploads is backend/uploads.
        
        if os.path.exists(upload_path):
            print(f"File stored locally at {upload_path}")
        else:
            print(f"File NOT found locally at {upload_path}. Checking root uploads...")
            if os.path.exists(f"uploads/{meeting_id}/{filename}"):
                 print(f"File stored locally at uploads/{meeting_id}/{filename}")

        # Clean up
        os.remove(filename)
        print("Verification complete!")

if __name__ == "__main__":
    asyncio.run(verify_stage_3())
