import pytest
from httpx import AsyncClient
from unittest.mock import patch, MagicMock, AsyncMock

@pytest.mark.asyncio
async def test_upload_document(client: AsyncClient):
    # 1. Create a meeting first to get an ID
    create_res = await client.post("/api/meetings/", json={
        "title": "Doc Test Meeting",
        "start_time": "2023-01-01T10:00:00",
        "status": "scheduled"
    })
    assert create_res.status_code == 200
    meeting_id = create_res.json()["id"]

    # 2. Mock ContextService
    with patch("app.api.documents.ContextService") as MockService:
        mock_instance = MockService.return_value
        from datetime import datetime
        mock_instance.process_document = AsyncMock(return_value={
            "id": 1, 
            "filename": "test.txt", 
            "file_type": "text/plain",
            "created_at": datetime.now(),
            "meeting_id": meeting_id,
            "status": "processed"
        })
        
        files = {"file": ("test.txt", b"This is a test document content.", "text/plain")}
        response = await client.post(f"/api/meetings/{meeting_id}/documents", files=files)
        
        if response.status_code != 200:
            print(f"Upload failed: {response.text}")
            
        assert response.status_code == 200
        data = response.json()
        assert data["filename"] == "test.txt"
        assert data["meeting_id"] == meeting_id

@pytest.mark.asyncio
async def test_list_documents(client: AsyncClient):
    # 1. Create meeting
    create_res = await client.post("/api/meetings/", json={
        "title": "List Doc Meeting",
        "start_time": "2023-01-01T10:00:00",
        "status": "scheduled"
    })
    meeting_id = create_res.json()["id"]

    # 2. Mock ContextService
    with patch("app.api.documents.ContextService") as MockService:
        mock_instance = MockService.return_value
        # Mock async method
        from unittest.mock import AsyncMock
        mock_instance.get_documents = AsyncMock(return_value=[])
        
        response = await client.get(f"/api/meetings/{meeting_id}/documents")
        assert response.status_code == 200
        assert isinstance(response.json(), list)
