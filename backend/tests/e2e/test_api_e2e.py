#!/usr/bin/env python3
"""
End-to-End API Testing Script using Playwright
Tests the macapy.io backend API endpoints

Usage:
    pytest backend/tests/e2e/test_api_e2e.py -v -s
    python backend/tests/e2e/test_api_e2e.py  # Run manually
"""
import json
import os
import sys
import pytest
import logging

logger = logging.getLogger(__name__)

# Configuration
BASE_URL = os.environ.get("API_BASE_URL", "http://localhost:8000")


def is_playwright_available():
    """Check if Playwright is available."""
    try:
        from playwright.sync_api import sync_playwright
        return True
    except ImportError:
        return False


def is_server_running():
    """Check if the backend server is running."""
    if not is_playwright_available():
        return False
    try:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            context = browser.new_context()
            page = context.new_page()
            try:
                response = page.request.get(f"{BASE_URL}/health", timeout=5000)
                browser.close()
                return response.ok
            except Exception:
                browser.close()
                return False
    except Exception:
        return False


# Skip all tests if Playwright is not available or server is not running
pytestmark = [
    pytest.mark.skipif(
        not is_playwright_available(),
        reason="Playwright not installed"
    ),
    pytest.mark.e2e
]


class TestAPIEndpoints:
    """E2E tests for API endpoints using Playwright."""

    @pytest.fixture(autouse=True)
    def skip_if_no_server(self):
        """Skip tests if server is not running."""
        if not is_server_running():
            pytest.skip("Backend server not running at " + BASE_URL)

    def test_health_check(self):
        """Test health endpoint."""
        from playwright.sync_api import sync_playwright

        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            context = browser.new_context()
            page = context.new_page()

            response = page.request.get(f"{BASE_URL}/health")
            assert response.ok, f"Health check failed: {response.status}"
            health = response.json()
            logger.info(f"Health check: {health.get('status', 'unknown')}")

            browser.close()

    def test_api_documentation(self):
        """Test that API docs are accessible and contain expected endpoints."""
        from playwright.sync_api import sync_playwright

        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            page = browser.new_page()

            # Test Swagger UI
            page.goto(f"{BASE_URL}/docs")
            page.wait_for_load_state('networkidle')

            # Take screenshot for debugging
            page.screenshot(path='/tmp/api_docs.png', full_page=True)
            logger.info("API Documentation loaded successfully")

            # Check for key endpoints in the docs
            content = page.content()
            expected_endpoints = [
                '/api/meetings',
                '/api/audio',
                '/api/transcripts',
                '/api/ai',
            ]

            for endpoint in expected_endpoints:
                if endpoint in content:
                    logger.info(f"  Found endpoint: {endpoint}")
                else:
                    logger.warning(f"  Missing endpoint: {endpoint}")

            browser.close()

    def test_meeting_crud(self):
        """Test Meeting CRUD operations."""
        from playwright.sync_api import sync_playwright

        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            context = browser.new_context()
            page = context.new_page()

            # Create meeting
            response = page.request.post(
                f"{BASE_URL}/api/meetings/",
                data=json.dumps({"title": "Playwright E2E Test", "platform": "test"}),
                headers={"Content-Type": "application/json"}
            )
            assert response.ok, f"Create meeting failed: {response.status}"
            meeting = response.json()
            meeting_id = meeting['id']
            logger.info(f"Created meeting: {meeting_id}")

            try:
                # Get meeting
                response = page.request.get(f"{BASE_URL}/api/meetings/{meeting_id}/")
                assert response.ok, f"Get meeting failed: {response.status}"
                logger.info(f"  Get meeting: {response.json()['title']}")

                # Update meeting status
                response = page.request.patch(
                    f"{BASE_URL}/api/meetings/{meeting_id}/",
                    data=json.dumps({"status": "IN_PROGRESS"}),
                    headers={"Content-Type": "application/json"}
                )
                assert response.ok, f"Update meeting failed: {response.status}"
                logger.info(f"  Updated status: {response.json()['status']}")

                # Get token usage (endpoint is under /api/ai prefix)
                response = page.request.get(f"{BASE_URL}/api/ai/meetings/{meeting_id}/tokens")
                assert response.ok, f"Get tokens failed: {response.status}"
                tokens = response.json()
                logger.info(f"  Token usage: {tokens['current_tokens']}/{tokens['max_tokens']}")

                # Complete meeting
                response = page.request.patch(
                    f"{BASE_URL}/api/meetings/{meeting_id}/",
                    data=json.dumps({"status": "COMPLETED"}),
                    headers={"Content-Type": "application/json"}
                )
                assert response.ok
                logger.info("  Completed meeting")

            finally:
                # Delete meeting (cleanup)
                response = page.request.delete(f"{BASE_URL}/api/meetings/{meeting_id}/")
                assert response.ok
                logger.info("  Deleted meeting")

            browser.close()

    def test_audio_endpoints(self):
        """Test audio device endpoints."""
        from playwright.sync_api import sync_playwright

        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            context = browser.new_context()
            page = context.new_page()

            # List audio devices
            response = page.request.get(f"{BASE_URL}/api/audio/devices/")
            if response.ok:
                devices = response.json()
                logger.info(f"Audio devices: {len(devices) if isinstance(devices, list) else 'N/A'} found")
                if isinstance(devices, list):
                    for d in devices[:3]:  # Show first 3
                        logger.info(f"  - {d.get('name', 'Unknown')}")
            else:
                logger.warning(f"Audio devices endpoint failed: {response.status}")

            # Get capture status
            response = page.request.get(f"{BASE_URL}/api/audio/status/")
            if response.ok:
                status = response.json()
                logger.info(f"Audio status: {status.get('status', 'unknown')}")

            browser.close()


def run_manual_tests():
    """Run tests manually without pytest."""
    from playwright.sync_api import sync_playwright

    print("=" * 50)
    print("macapy.io Backend E2E Tests")
    print("=" * 50)
    print()

    # Check if server is running
    if not is_server_running():
        print(f"[ERROR] Backend server not running at {BASE_URL}")
        print("        Start the server with: uvicorn backend.app.main:app --reload")
        sys.exit(1)

    print("1. Health Check")
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        page = context.new_page()

        response = page.request.get(f"{BASE_URL}/health")
        assert response.ok
        health = response.json()
        print(f"   [OK] Health check: {health.get('status', 'unknown')}")
        browser.close()
    print()

    print("2. API Documentation")
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()
        page.goto(f"{BASE_URL}/docs")
        page.wait_for_load_state('networkidle')
        page.screenshot(path='/tmp/api_docs.png', full_page=True)
        print("   [OK] API Documentation loaded successfully")

        content = page.content()
        expected_endpoints = ['/api/meetings', '/api/audio', '/api/transcripts', '/api/ai']
        for endpoint in expected_endpoints:
            if endpoint in content:
                print(f"   [OK] Found endpoint: {endpoint}")
            else:
                print(f"   [WARN] Missing endpoint: {endpoint}")
        browser.close()
    print()

    print("3. Meeting CRUD Operations")
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        page = context.new_page()

        # Create meeting
        response = page.request.post(
            f"{BASE_URL}/api/meetings/",
            data=json.dumps({"title": "Playwright E2E Test", "platform": "test"}),
            headers={"Content-Type": "application/json"}
        )
        assert response.ok, f"Create meeting failed: {response.status}"
        meeting = response.json()
        meeting_id = meeting['id']
        print(f"   [OK] Created meeting: {meeting_id}")

        # Get meeting
        response = page.request.get(f"{BASE_URL}/api/meetings/{meeting_id}/")
        assert response.ok, f"Get meeting failed: {response.status}"
        print(f"   [OK] Get meeting: {response.json()['title']}")

        # Delete meeting
        response = page.request.delete(f"{BASE_URL}/api/meetings/{meeting_id}/")
        assert response.ok
        print("   [OK] Deleted meeting")
        browser.close()
    print()

    print("4. Audio Endpoints")
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        page = context.new_page()

        response = page.request.get(f"{BASE_URL}/api/audio/devices/")
        if response.ok:
            devices = response.json()
            print(f"   [OK] Audio devices: {len(devices) if isinstance(devices, list) else 'N/A'} found")
        else:
            print(f"   [WARN] Audio devices endpoint failed: {response.status}")

        browser.close()
    print()

    print("=" * 50)
    print("All E2E tests completed!")
    print("=" * 50)


if __name__ == "__main__":
    if not is_playwright_available():
        print("[ERROR] Playwright not installed")
        print("        Install with: pip install playwright && playwright install chromium")
        sys.exit(1)

    run_manual_tests()
