# Development Scripts

This directory contains utility scripts for development, debugging, and manual verification.

**IMPORTANT**: These are NOT pytest tests. Actual tests are in `backend/tests/`.

## Available Scripts

### API & Database
- `manual_api_test.py`: Manual API endpoint testing via HTTP requests
- `inspect_db.py`: Database inspection utility
- `status_report.py`: Generate system status reports

### Audio Capture
- `test_mic_audio.py`: Debug microphone audio capture
- `test_system_audio.py`: Debug system/loopback audio capture
- `verify_audio_capture.py`: Verify audio capture functionality
- `verify_audio_flow.py`: End-to-end audio pipeline verification
- `verify_audio_integration.py`: Audio integration testing

### External Services
- `validate_openai_key.py`: Verify OpenAI API key is valid
- `verify_document_feedback.py`: Test document processing pipeline

## Usage

Run these scripts from the project root with the virtual environment activated:

```bash
# Activate virtual environment first
source .venv/bin/activate

# Run a script
python -m backend.scripts.validate_openai_key
python -m backend.scripts.verify_audio_capture
```

## Note

For automated testing, use pytest:

```bash
pytest backend/tests/unit/ -v        # Unit tests
pytest backend/tests/integration/ -v  # Integration tests
pytest backend/tests/e2e/ -v          # End-to-end tests
```
