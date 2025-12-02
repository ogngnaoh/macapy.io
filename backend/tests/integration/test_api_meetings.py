import pytest
from unittest.mock import AsyncMock, patch
from httpx import AsyncClient

@pytest.mark.asyncio
async def test_create_meeting(client: AsyncClient):
    response = await client.post("/api/meetings/", json={
        "title": "Test Meeting",
        "start_time": "2023-01-01T10:00:00",
        "status": "PENDING"
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
        "status": "PENDING"
    })

    response = await client.get("/api/meetings/")
    assert response.status_code == 200
    data = response.json()
    assert isinstance(data, list)
    assert len(data) > 0

@pytest.mark.asyncio
async def test_update_meeting_status(client: AsyncClient):
    """Test meeting status updates.

    Note: We mock meeting_service methods to avoid event loop conflicts
    that occur when the service creates its own database sessions.
    """
    # Create
    create_res = await client.post("/api/meetings/", json={
        "title": "Meeting to Update",
        "start_time": "2023-01-01T14:00:00",
        "status": "PENDING"
    })
    meeting_id = create_res.json()["id"]

    # Mock meeting_service to avoid event loop conflicts in tests
    # The service is imported inside the update_meeting function, so we patch where it comes from
    with patch('app.services.meeting_service.meeting_service') as mock_service:
        mock_service.start_meeting = AsyncMock()
        mock_service.stop_meeting = AsyncMock()

        # Update to in_progress
        response = await client.patch(f"/api/meetings/{meeting_id}", json={"status": "IN_PROGRESS"})
        assert response.status_code == 200
        assert response.json()["status"] == "IN_PROGRESS"

        # Update to completed
        response = await client.patch(f"/api/meetings/{meeting_id}", json={"status": "COMPLETED"})
        assert response.status_code == 200
        assert response.json()["status"] == "COMPLETED"
