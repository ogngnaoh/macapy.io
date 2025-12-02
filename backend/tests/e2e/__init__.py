# E2E tests for macapy.io
#
# These tests require specific environments to run:
# - test_audio_manual.py: macOS 12.3+ with ScreenCaptureKit
# - test_audio_e2e.py: macOS 12.3+ with ScreenCaptureKit
# - test_api_e2e.py: Backend server running at localhost:8000 + Playwright
# - test_webapp_audio.py: Both frontend and backend running + Playwright
#
# Run with:
#   pytest backend/tests/e2e/ -v -s
#
# Or run individual tests:
#   pytest backend/tests/e2e/test_audio_manual.py -v -s
#   python backend/tests/e2e/test_audio_manual.py --list
