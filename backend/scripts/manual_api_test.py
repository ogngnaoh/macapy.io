import requests
import json

API_URL = "http://localhost:8000/api"

def test_create_meeting():
    print("Testing POST /meetings/...")
    try:
        response = requests.post(f"{API_URL}/meetings/", json={
            "title": "API Test Meeting",
            "start_time": "2023-10-27T10:00:00Z",
            "status": "scheduled"
        })
        if response.status_code == 200:
            print("✅ Create Meeting Passed")
            return response.json()
        else:
            print(f"❌ Create Meeting Failed: {response.status_code} - {response.text}")
            return None
    except Exception as e:
        print(f"❌ Create Meeting Exception: {e}")
        return None

def test_start_meeting(meeting_id):
    print(f"Testing PATCH /meetings/{meeting_id}...")
    try:
        response = requests.patch(f"{API_URL}/meetings/{meeting_id}", json={
            "status": "in_progress"
        })
        if response.status_code == 200:
            print("✅ Start Meeting Passed")
            return response.json()
        else:
            print(f"❌ Start Meeting Failed: {response.status_code} - {response.text}")
            return None
    except Exception as e:
        print(f"❌ Start Meeting Exception: {e}")
        return None

if __name__ == "__main__":
    meeting = test_create_meeting()
    if meeting:
        test_start_meeting(meeting['id'])
