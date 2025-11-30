#!/usr/bin/env python3
"""
Diagnostic script to test OpenAI Responses API directly.

This script verifies:
1. API key is valid
2. Model ID is correct
3. Response structure matches our extraction logic
4. Streaming events work correctly

Run with:
    python backend/scripts/test_llm_responses_api.py

Or from project root with venv:
    source .venv/bin/activate
    python backend/scripts/test_llm_responses_api.py
"""
import asyncio
import os
import sys
from pathlib import Path

# Add project root to path for imports
project_root = Path(__file__).resolve().parent.parent.parent
sys.path.insert(0, str(project_root))

from openai import AsyncOpenAI


async def load_settings():
    """Load settings from config."""
    try:
        from backend.app.config import settings
        return {
            "api_key": settings.OPENAI_API_KEY,
            "model": settings.GPT_MODEL,
        }
    except Exception as e:
        print(f"Failed to load settings from config: {e}")
        # Fallback to environment variables
        return {
            "api_key": os.getenv("OPENAI_API_KEY"),
            "model": os.getenv("GPT_MODEL", "gpt-5-nano-2025-08-07"),
        }


def extract_text_from_response(response) -> str:
    """
    Extract text using the same logic as LLMService._extract_text_from_response().
    This validates that our extraction logic matches the actual response structure.
    """
    try:
        if not response.output:
            return ""

        for item in response.output:
            if hasattr(item, 'type') and item.type == "message":
                if hasattr(item, 'content') and item.content:
                    for content_part in item.content:
                        if hasattr(content_part, 'type') and content_part.type == "output_text":
                            return content_part.text
                        elif hasattr(content_part, 'text'):
                            return content_part.text
        return ""
    except Exception as e:
        print(f"  Extract error: {e}")
        return ""


async def test_basic_response(client: AsyncOpenAI, model: str) -> bool:
    """Test basic non-streaming response."""
    print("=" * 60)
    print("TEST 1: Basic Responses API Call (Non-Streaming)")
    print("=" * 60)
    print(f"Model: {model}")

    try:
        response = await client.responses.create(
            model=model,
            instructions="You are a helpful assistant. Always provide a complete response.",
            input="Say 'Hello, World!' and nothing else.",
            max_output_tokens=100,
            reasoning={"effort": "low"}  # Enable reasoning for GPT-5 nano
        )

        print("\nResponse received successfully!")
        print(f"  response.id: {response.id}")
        print(f"  response.status: {response.status}")
        print(f"  response.model: {response.model}")
        print(f"  response.output type: {type(response.output)}")
        print(f"  response.output length: {len(response.output) if response.output else 0}")

        if response.output:
            print("\n  Output structure:")
            for i, item in enumerate(response.output):
                item_type = getattr(item, 'type', 'N/A')
                print(f"    output[{i}].type: {item_type}")

                if hasattr(item, 'content') and item.content:
                    for j, content in enumerate(item.content or []):
                        content_type = getattr(content, 'type', 'N/A')
                        content_text = getattr(content, 'text', 'N/A')
                        print(f"      content[{j}].type: {content_type}")
                        print(f"      content[{j}].text: {content_text[:100] if content_text else 'N/A'}")

        # Extract text using our method
        text = extract_text_from_response(response)
        print(f"\n  Extracted text: '{text}'")

        if text:
            print("\n  RESULT: PASS - Text extraction working correctly")
            return True
        else:
            print("\n  RESULT: FAIL - No text extracted (check response structure)")
            return False

    except Exception as e:
        print(f"\n  ERROR: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        print("\n  RESULT: FAIL - API call failed")
        return False


async def test_streaming_response(client: AsyncOpenAI, model: str) -> bool:
    """Test streaming response."""
    print("\n" + "=" * 60)
    print("TEST 2: Streaming Responses API Call")
    print("=" * 60)
    print(f"Model: {model}")

    try:
        response = await client.responses.create(
            model=model,
            instructions="You are a helpful assistant. Always provide a complete response.",
            input="Count from 1 to 5, one number per line.",
            max_output_tokens=100,
            reasoning={"effort": "low"},  # Enable reasoning for GPT-5 nano
            stream=True
        )

        print("\nStreaming events received:")
        chunks = []
        event_types_seen = set()

        async for event in response:
            event_type = getattr(event, 'type', 'unknown')
            delta = getattr(event, 'delta', None)
            event_types_seen.add(event_type)

            if delta:
                print(f"  Event: {event_type}, Delta: {repr(delta)}")
                chunks.append(delta)
            else:
                # Log other event types without delta
                if event_type not in ['response.created', 'response.in_progress', 'response.completed']:
                    print(f"  Event: {event_type} (no delta)")

        combined = ''.join(chunks)
        print(f"\n  Combined output: '{combined}'")
        print(f"  Event types seen: {event_types_seen}")

        if combined.strip():
            print("\n  RESULT: PASS - Streaming working correctly")
            return True
        else:
            print("\n  RESULT: FAIL - No text chunks received")
            return False

    except Exception as e:
        print(f"\n  ERROR: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        print("\n  RESULT: FAIL - Streaming API call failed")
        return False


async def test_summary_generation(client: AsyncOpenAI, model: str) -> bool:
    """Test summary generation with realistic prompt."""
    print("\n" + "=" * 60)
    print("TEST 3: Summary Generation (Realistic Prompt)")
    print("=" * 60)

    transcript = """
    [Speaker 1]: Welcome everyone to our product sync meeting.
    [Speaker 2]: Thanks for having us. I wanted to discuss the Q4 roadmap.
    [Speaker 1]: Great, what are the main priorities?
    [Speaker 2]: We need to focus on performance improvements and the new dashboard feature.
    [Speaker 1]: What's the timeline for the dashboard?
    [Speaker 2]: We're targeting mid-December for the beta release.
    """

    prompt = f"""Summarize the following conversation segment.
Focus on: key decisions, action items, and important questions raised.
Keep it concise (under 3 bullet points).

Transcript:
{transcript}"""

    try:
        response = await client.responses.create(
            model=model,
            instructions="You are a helpful meeting assistant. Always provide a complete summary response.",
            input=prompt,
            max_output_tokens=500,
            reasoning={"effort": "low"}  # Enable reasoning for GPT-5 nano
        )

        text = extract_text_from_response(response)
        print(f"\n  Generated summary:\n{text}")

        if text and len(text) > 20:
            print("\n  RESULT: PASS - Summary generation working")
            return True
        else:
            print("\n  RESULT: FAIL - Summary too short or empty")
            return False

    except Exception as e:
        print(f"\n  ERROR: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        print("\n  RESULT: FAIL - Summary generation failed")
        return False


async def test_json_output(client: AsyncOpenAI, model: str) -> bool:
    """Test JSON structured output for suggestions."""
    print("\n" + "=" * 60)
    print("TEST 4: JSON Output (Suggestions Format)")
    print("=" * 60)

    prompt = """Provide 3 distinct, conversational response options for someone asked:
"What are your thoughts on using microservices architecture?"

Return as JSON with format: {"suggestions": ["response1", "response2", "response3"]}"""

    try:
        response = await client.responses.create(
            model=model,
            instructions="You are a helpful assistant. Always respond with valid JSON.",
            input=prompt,
            text={"format": {"type": "json_object"}}
        )

        text = extract_text_from_response(response)
        print(f"\n  Raw response: {text[:500] if text else 'N/A'}")

        if text:
            import json
            try:
                data = json.loads(text)
                if "suggestions" in data and isinstance(data["suggestions"], list):
                    print(f"  Parsed suggestions: {data['suggestions']}")
                    print("\n  RESULT: PASS - JSON output working")
                    return True
                else:
                    print("  Missing 'suggestions' key or not a list")
                    print("\n  RESULT: FAIL - JSON structure incorrect")
                    return False
            except json.JSONDecodeError as e:
                print(f"  JSON parse error: {e}")
                print("\n  RESULT: FAIL - Invalid JSON")
                return False
        else:
            print("\n  RESULT: FAIL - No response text")
            return False

    except Exception as e:
        print(f"\n  ERROR: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()
        print("\n  RESULT: FAIL - JSON output test failed")
        return False


async def main():
    """Run all diagnostic tests."""
    print("\n" + "=" * 60)
    print("OpenAI Responses API Diagnostic Test")
    print("macapy.io LLM Service Verification")
    print("=" * 60)

    # Load settings
    config = await load_settings()

    if not config["api_key"]:
        print("\nERROR: No OpenAI API key found!")
        print("Set OPENAI_API_KEY in .env or environment")
        sys.exit(1)

    print(f"\nConfiguration:")
    print(f"  API Key: {config['api_key'][:10]}...{config['api_key'][-4:]}")
    print(f"  Model: {config['model']}")

    # Create client
    client = AsyncOpenAI(api_key=config["api_key"])

    # Run tests
    results = {}
    results["basic"] = await test_basic_response(client, config["model"])
    results["streaming"] = await test_streaming_response(client, config["model"])
    results["summary"] = await test_summary_generation(client, config["model"])
    results["json"] = await test_json_output(client, config["model"])

    # Summary
    print("\n" + "=" * 60)
    print("RESULTS SUMMARY")
    print("=" * 60)

    all_passed = True
    for test, passed in results.items():
        status = "PASS" if passed else "FAIL"
        symbol = "[OK]" if passed else "[X]"
        print(f"  {symbol} {test}: {status}")
        if not passed:
            all_passed = False

    print()
    if all_passed:
        print("All tests passed! LLM service should work correctly.")
        print("If you're still seeing issues, check:")
        print("  1. Database has transcript data")
        print("  2. Backend logs for other errors")
        print("  3. Frontend console for network issues")
    else:
        print("Some tests failed! Check the error messages above.")
        print("\nCommon issues:")
        print("  - Invalid model ID (try 'gpt-5-nano-2025-08-07')")
        print("  - Expired or invalid API key")
        print("  - Rate limiting (wait and retry)")

    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
