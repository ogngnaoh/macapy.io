"""
Comprehensive macapy.io Status Report Generator
Tests all components: Database, Backend API, Frontend, Integration
"""
import requests
import json
import subprocess
from datetime import datetime

BACKEND_URL = "http://localhost:8000"
FRONTEND_URL = "http://localhost:5173"

def print_section(title):
    print(f"\n{'='*60}")
    print(f" {title}")
    print('='*60)

def check_database():
    """Check PostgreSQL and pgvector"""
    print_section("DATABASE STATUS")

    results = {"postgresql": False, "pgvector": False, "tables": []}

    try:
        # Check PostgreSQL
        result = subprocess.run(
            ["/opt/homebrew/opt/postgresql@18/bin/psql", "-U", "hoangngo", "-d", "macapy_db", "-c", "SELECT version();"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            results["postgresql"] = True
            version = result.stdout.split('\n')[2].strip()[:50]
            print(f"  PostgreSQL: RUNNING - {version}...")
        else:
            print(f"  PostgreSQL: ERROR - {result.stderr[:100]}")
    except Exception as e:
        print(f"  PostgreSQL: ERROR - {e}")

    try:
        # Check pgvector
        result = subprocess.run(
            ["/opt/homebrew/opt/postgresql@18/bin/psql", "-U", "hoangngo", "-d", "macapy_db", "-c", "SELECT extversion FROM pg_extension WHERE extname='vector';"],
            capture_output=True, text=True, timeout=5
        )
        if "1." in result.stdout:
            results["pgvector"] = True
            print(f"  pgvector: INSTALLED")
        else:
            print(f"  pgvector: NOT FOUND")
    except Exception as e:
        print(f"  pgvector: ERROR - {e}")

    try:
        # Check tables
        result = subprocess.run(
            ["/opt/homebrew/opt/postgresql@18/bin/psql", "-U", "hoangngo", "-d", "macapy_db", "-c", "\\dt"],
            capture_output=True, text=True, timeout=5
        )
        tables = [line.split('|')[1].strip() for line in result.stdout.split('\n') if '|' in line and 'public' in line]
        results["tables"] = tables
        print(f"  Tables: {len(tables)} found")
        for t in tables:
            print(f"    - {t}")
    except Exception as e:
        print(f"  Tables: ERROR - {e}")

    return results

def check_backend():
    """Check Backend API endpoints"""
    print_section("BACKEND API STATUS")

    results = {
        "health": False,
        "meetings_crud": False,
        "audio_devices": False,
        "documents": False,
        "websocket_endpoint": False
    }

    # Health check
    try:
        resp = requests.get(f"{BACKEND_URL}/health", timeout=5)
        results["health"] = resp.status_code == 200
        print(f"  /health: {'OK' if results['health'] else 'FAIL'} ({resp.status_code})")
    except Exception as e:
        print(f"  /health: ERROR - {e}")

    # Meetings CRUD
    try:
        # Create
        resp = requests.post(f"{BACKEND_URL}/api/meetings/", json={"title": "Status Test"}, timeout=5)
        if resp.status_code == 200:
            meeting = resp.json()
            meeting_id = meeting["id"]

            # Read
            resp = requests.get(f"{BACKEND_URL}/api/meetings/{meeting_id}", timeout=5)
            read_ok = resp.status_code == 200

            # List
            resp = requests.get(f"{BACKEND_URL}/api/meetings/", timeout=5)
            list_ok = resp.status_code == 200
            meetings_count = len(resp.json()) if list_ok else 0

            # Delete
            resp = requests.delete(f"{BACKEND_URL}/api/meetings/{meeting_id}", timeout=5)
            delete_ok = resp.status_code == 200

            results["meetings_crud"] = read_ok and list_ok and delete_ok
            print(f"  /api/meetings: {'OK' if results['meetings_crud'] else 'PARTIAL'} (CRUD works, {meetings_count} meetings in DB)")
        else:
            print(f"  /api/meetings: FAIL (create failed: {resp.status_code})")
    except Exception as e:
        print(f"  /api/meetings: ERROR - {e}")

    # Audio devices
    try:
        resp = requests.get(f"{BACKEND_URL}/api/audio/devices/", timeout=5)
        results["audio_devices"] = resp.status_code == 200
        devices = resp.json() if results["audio_devices"] else []
        print(f"  /api/audio/devices: {'OK' if results['audio_devices'] else 'FAIL'} ({len(devices)} devices)")
        for d in devices[:3]:
            loopback = " [LOOPBACK]" if d.get("is_loopback") else ""
            default = " [DEFAULT]" if d.get("is_default") else ""
            print(f"    - {d['name'][:40]}{loopback}{default}")
    except Exception as e:
        print(f"  /api/audio/devices: ERROR - {e}")

    # Documents endpoint
    try:
        resp = requests.get(f"{BACKEND_URL}/api/documents/", timeout=5)
        results["documents"] = resp.status_code == 200
        print(f"  /api/documents: {'OK' if results['documents'] else 'FAIL'} ({resp.status_code})")
    except Exception as e:
        print(f"  /api/documents: ERROR - {e}")

    # WebSocket endpoint exists
    try:
        resp = requests.get(f"{BACKEND_URL}/docs", timeout=5)
        results["websocket_endpoint"] = "/api/ws/meeting" in resp.text
        print(f"  WebSocket /api/ws/meeting: {'CONFIGURED' if results['websocket_endpoint'] else 'NOT FOUND'}")
    except Exception as e:
        print(f"  WebSocket: ERROR - {e}")

    return results

def check_frontend():
    """Check Frontend availability"""
    print_section("FRONTEND STATUS")

    results = {
        "server_running": False,
        "html_loads": False,
        "react_app": False
    }

    try:
        resp = requests.get(FRONTEND_URL, timeout=5)
        results["server_running"] = resp.status_code == 200
        results["html_loads"] = "<!DOCTYPE html>" in resp.text
        results["react_app"] = "vite" in resp.text.lower() or "react" in resp.text.lower()

        print(f"  Server: {'RUNNING' if results['server_running'] else 'DOWN'} on port 5173")
        print(f"  HTML: {'OK' if results['html_loads'] else 'FAIL'}")
        print(f"  React/Vite: {'CONFIGURED' if results['react_app'] else 'NOT DETECTED'}")
    except Exception as e:
        print(f"  Frontend: ERROR - {e}")

    return results

def check_cors():
    """Check CORS configuration"""
    print_section("CORS CONFIGURATION")

    results = {"cors_enabled": False}

    try:
        resp = requests.options(
            f"{BACKEND_URL}/api/meetings/",
            headers={
                "Origin": "http://localhost:5173",
                "Access-Control-Request-Method": "GET"
            },
            timeout=5
        )
        cors_header = resp.headers.get("access-control-allow-origin", "")
        results["cors_enabled"] = "localhost:5173" in cors_header

        print(f"  CORS for localhost:5173: {'ENABLED' if results['cors_enabled'] else 'DISABLED'}")
        print(f"  Allow-Origin Header: {cors_header or 'Not set'}")
    except Exception as e:
        print(f"  CORS: ERROR - {e}")

    return results

def check_audio_capture_config():
    """Check audio capture configuration for macOS"""
    print_section("AUDIO CAPTURE CONFIG (macOS)")

    import platform
    results = {
        "platform": platform.system(),
        "backend": "sounddevice" if platform.system() != "Windows" else "pyaudiowpatch",
        "dual_capture": False,
        "screencapturekit": False
    }

    print(f"  Platform: {results['platform']}")
    print(f"  Audio Backend: {results['backend']}")
    print(f"  Dual Capture (system+mic): NOT IMPLEMENTED for macOS")
    print(f"  ScreenCaptureKit: NOT IMPLEMENTED (recommended)")
    print(f"  BlackHole Required: YES (current implementation)")

    return results

def generate_report():
    """Generate full status report"""
    print("\n" + "="*60)
    print(" MACAPY.IO STATUS REPORT")
    print(f" Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("="*60)

    db = check_database()
    backend = check_backend()
    frontend = check_frontend()
    cors = check_cors()
    audio = check_audio_capture_config()

    # Summary
    print_section("SUMMARY")

    all_checks = {
        "Database (PostgreSQL)": db["postgresql"],
        "Database (pgvector)": db["pgvector"],
        "Backend Health": backend["health"],
        "Backend Meetings API": backend["meetings_crud"],
        "Backend Audio API": backend["audio_devices"],
        "Frontend Server": frontend["server_running"],
        "Frontend React App": frontend["react_app"],
        "CORS Configuration": cors["cors_enabled"],
    }

    passed = sum(1 for v in all_checks.values() if v)
    total = len(all_checks)

    for check, status in all_checks.items():
        icon = "PASS" if status else "FAIL"
        print(f"  [{icon}] {check}")

    print(f"\n  Overall: {passed}/{total} checks passed")

    # Issues
    issues = []
    if not cors["cors_enabled"]:
        issues.append("CORS not configured for localhost:5173")
    if audio["platform"] == "Darwin" and not audio["screencapturekit"]:
        issues.append("macOS: ScreenCaptureKit not implemented (using sounddevice)")

    if issues:
        print("\n  Issues to Address:")
        for issue in issues:
            print(f"    - {issue}")

    return passed == total

if __name__ == "__main__":
    success = generate_report()
    print("\n" + "="*60)
    exit(0 if success else 1)
