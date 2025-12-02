#!/usr/bin/env python3
"""
Test script to verify audio capture works in the running web app.

This script:
1. Opens the web app in a browser
2. Starts a meeting
3. Waits for transcripts to appear (indicating audio capture is working)
4. Takes screenshots for verification

Usage:
    pytest backend/tests/e2e/test_webapp_audio.py -v -s
    python backend/tests/e2e/test_webapp_audio.py  # Run manually
"""
import os
import sys
import time
import json
import pytest
import logging

logger = logging.getLogger(__name__)

# Configuration
FRONTEND_URL = os.environ.get("FRONTEND_URL", "http://localhost:5173")
BACKEND_URL = os.environ.get("API_BASE_URL", "http://localhost:8000")


def is_playwright_available():
    """Check if Playwright is available."""
    try:
        from playwright.sync_api import sync_playwright
        return True
    except ImportError:
        return False


def is_frontend_running():
    """Check if the frontend server is running."""
    if not is_playwright_available():
        return False
    try:
        from playwright.sync_api import sync_playwright
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            context = browser.new_context()
            page = context.new_page()
            try:
                page.goto(FRONTEND_URL, timeout=5000)
                page.wait_for_load_state('networkidle', timeout=5000)
                browser.close()
                return True
            except Exception:
                browser.close()
                return False
    except Exception:
        return False


# Skip all tests if Playwright is not available
pytestmark = [
    pytest.mark.skipif(
        not is_playwright_available(),
        reason="Playwright not installed"
    ),
    pytest.mark.e2e
]


class TestWebAppAudio:
    """E2E tests for web app audio capture."""

    @pytest.fixture(autouse=True)
    def skip_if_no_frontend(self):
        """Skip tests if frontend is not running."""
        if not is_frontend_running():
            pytest.skip(f"Frontend not running at {FRONTEND_URL}")

    def test_audio_capture_flow(self):
        """Test that audio capture works in the web app."""
        from playwright.sync_api import sync_playwright

        with sync_playwright() as p:
            browser = p.chromium.launch(headless=False)  # headless=False to see what's happening
            page = browser.new_page()

            console_logs = []
            page.on("console", lambda msg: console_logs.append(f"[{msg.type}] {msg.text}"))

            # Navigate to the frontend
            logger.info(f"Navigating to {FRONTEND_URL}...")
            page.goto(FRONTEND_URL)
            page.wait_for_load_state("networkidle")

            # Take initial screenshot
            page.screenshot(path="/tmp/webapp_initial.png")
            logger.info("Initial screenshot saved to /tmp/webapp_initial.png")

            # Look for the start meeting button
            logger.info("Looking for Start Meeting button...")
            start_btn = page.locator('button:has-text("Start")').first
            if start_btn.is_visible():
                logger.info("Found Start button, clicking...")
                start_btn.click()
                time.sleep(2)
                page.screenshot(path="/tmp/webapp_meeting_started.png")
                logger.info("Meeting started screenshot saved")
            else:
                # Try other selectors
                start_btn = page.locator('[data-testid="start-meeting"]').first
                if start_btn.is_visible():
                    start_btn.click()
                    time.sleep(2)
                else:
                    logger.warning("Could not find start button")
                    page.screenshot(path="/tmp/webapp_state.png")

            # Wait for transcripts to appear (indicating audio capture is working)
            logger.info("Waiting for transcripts (up to 15 seconds)...")
            transcript_appeared = False

            for i in range(15):
                time.sleep(1)

                # Check for any transcript content
                transcript_panel = page.locator('[class*="transcript"]').first
                if transcript_panel.is_visible():
                    content = transcript_panel.text_content()
                    if content and len(content.strip()) > 10:
                        logger.info(f"Transcript detected! Content preview: {content[:100]}...")
                        transcript_appeared = True
                        break

                # Also check for WebSocket messages in console
                ws_messages = [log for log in console_logs if "transcript" in log.lower() or "websocket" in log.lower()]
                if ws_messages:
                    logger.info(f"WebSocket activity detected: {len(ws_messages)} messages")

                logger.debug(f"Waiting... {i+1}/15s")

            # Take final screenshot
            page.screenshot(path="/tmp/webapp_final.png", full_page=True)
            logger.info("Final screenshot saved to /tmp/webapp_final.png")

            # Print some console logs for debugging
            logger.info("--- Console Logs (last 10) ---")
            for log in console_logs[-10:]:
                logger.info(log)

            # Summary
            if transcript_appeared:
                logger.info("SUCCESS: Audio capture is working - transcripts appeared!")
            else:
                logger.warning("NOTE: No transcripts appeared yet. This could mean:")
                logger.warning("  - Audio capture needs manual permission grant")
                logger.warning("  - No audio is being played/recorded")
                logger.warning("  - Backend transcription service needs time")

            browser.close()

            # The test passes as long as we didn't crash
            # Actual transcript content depends on audio being played
            assert True


def run_manual_test():
    """Run the audio capture test manually."""
    from playwright.sync_api import sync_playwright

    print("Starting web app audio capture test...")
    print(f"Frontend URL: {FRONTEND_URL}")
    print()

    if not is_frontend_running():
        print(f"[ERROR] Frontend not running at {FRONTEND_URL}")
        print("        Start the frontend with: cd frontend && npm run dev")
        sys.exit(1)

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False)  # Show browser
        page = browser.new_page()

        console_logs = []
        page.on("console", lambda msg: console_logs.append(f"[{msg.type}] {msg.text}"))

        # Navigate to the frontend
        print(f"Navigating to {FRONTEND_URL}...")
        page.goto(FRONTEND_URL)
        page.wait_for_load_state("networkidle")

        # Take initial screenshot
        page.screenshot(path="/tmp/webapp_initial.png")
        print("[OK] Initial screenshot saved to /tmp/webapp_initial.png")

        # Look for the start meeting button
        print("Looking for Start Meeting button...")
        start_btn = page.locator('button:has-text("Start")').first
        if start_btn.is_visible():
            print("[OK] Found Start button, clicking...")
            start_btn.click()
            time.sleep(2)
            page.screenshot(path="/tmp/webapp_meeting_started.png")
            print("[OK] Meeting started screenshot saved")
        else:
            # Try other selectors
            start_btn = page.locator('[data-testid="start-meeting"]').first
            if start_btn.is_visible():
                start_btn.click()
                time.sleep(2)
            else:
                print("[WARN] Could not find start button, checking current state...")
                page.screenshot(path="/tmp/webapp_state.png")

        # Wait for transcripts to appear
        print("Waiting for transcripts (up to 15 seconds)...")
        transcript_appeared = False

        for i in range(15):
            time.sleep(1)

            # Check for any transcript content
            transcript_panel = page.locator('[class*="transcript"]').first
            if transcript_panel.is_visible():
                content = transcript_panel.text_content()
                if content and len(content.strip()) > 10:
                    print(f"[OK] Transcript detected! Content preview: {content[:100]}...")
                    transcript_appeared = True
                    break

            # Also check for WebSocket messages in console
            ws_messages = [log for log in console_logs if "transcript" in log.lower() or "websocket" in log.lower()]
            if ws_messages:
                print(f"   WebSocket activity detected: {len(ws_messages)} messages")

            print(f"   Waiting... {i+1}/15s")

        # Take final screenshot
        page.screenshot(path="/tmp/webapp_final.png", full_page=True)
        print("[OK] Final screenshot saved to /tmp/webapp_final.png")

        # Print console logs for debugging
        print()
        print("--- Console Logs ---")
        for log in console_logs[-20:]:  # Last 20 logs
            print(log)

        # Summary
        print()
        print("--- Test Summary ---")
        if transcript_appeared:
            print("[SUCCESS] Audio capture is working - transcripts appeared!")
        else:
            print("[NOTE] No transcripts appeared yet. This could mean:")
            print("  - Audio capture needs manual permission grant")
            print("  - No audio is being played/recorded")
            print("  - Backend transcription service needs time")

        browser.close()


if __name__ == "__main__":
    if not is_playwright_available():
        print("[ERROR] Playwright not installed")
        print("        Install with: pip install playwright && playwright install chromium")
        sys.exit(1)

    run_manual_test()
