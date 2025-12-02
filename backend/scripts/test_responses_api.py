#!/usr/bin/env python3
"""Test OpenAI Responses API directly."""

import asyncio
import os
import openai

async def test_responses_api():
    client = openai.AsyncOpenAI()  # Uses OPENAI_API_KEY env var
    model = "gpt-5.1-chat-latest"

    print(f"Testing Responses API with model: {model}")
    print("=" * 50)

    try:
        resp = await client.responses.create(
            model=model,
            input="Hello, how are you today?",
            max_output_tokens=100
        )

        print(f"Response type: {type(resp).__name__}")
        print(f"Response attrs: {[a for a in dir(resp) if not a.startswith('_')]}")

        if hasattr(resp, 'output'):
            print(f"\nOutput: {resp.output}")
            for i, item in enumerate(resp.output):
                print(f"\n  output[{i}]:")
                print(f"    type: {getattr(item, 'type', 'N/A')}")
                if hasattr(item, 'content'):
                    print(f"    content: {item.content}")
                if hasattr(item, 'text'):
                    print(f"    text: {item.text}")

        if hasattr(resp, 'output_text'):
            print(f"\noutput_text: {resp.output_text}")

    except Exception as e:
        print(f"Error: {type(e).__name__}: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    asyncio.run(test_responses_api())
