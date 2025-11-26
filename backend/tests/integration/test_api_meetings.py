import pytest
from httpx import AsyncClient

@pytest.mark.asyncio
async def test_create_meeting(client: AsyncClient):
    response = await client.post("/api/meetings/", json={
        "title": "Test Meeting",
        "start_time": "2023-01-01T10:00:00",
        "status": "scheduled"
    })
    assert response.status_code == 200
    data = response.json()
    assert data["title"] == "Test Meeting"
    assert "id" in data

@pytest.mark.asyncio
async def test_get_meetings(client: AsyncClient):
    # Create a meeting first
    await client.post("/api/meetings/", json={
        "title": "Meeting to List",
        "start_time": "2023-01-01T12:00:00",
        "status": "scheduled"
    })
    
    response = await client.get("/api/meetings/")
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, list)
    assert len(data) > 0

@pytest.mark.asyncio
async def test_update_meeting_status(client: AsyncClient):
    # Create
    create_res = await client.post("/api/meetings/", json={
        "title": "Meeting to Update",
        "start_time": "2023-01-01T14:00:00",
        "status": "scheduled"
    })
    meeting_id = create_res.json()["id"]

    # Update to in_progress
    response = await client.patch(f"/api/meetings/{meeting_id}", json={"status": "in_progress"})
    assert response.status_code == 200
    assert response.json()["status"] == "in_progress"

    # Update to completed
    response = await client.patch(f"/api/meetings/{meeting_id}", json={"status": "completed"})
    assert response.status_code == 200
    assert response.json()["status"] == "completed"
