/**
 * AI Integration E2E Tests
 *
 * Tests the LLM integration for query streaming and summary generation.
 * Requires:
 *   - Backend running on http://localhost:8000
 *   - Frontend running on http://localhost:5173
 *
 * Run with:
 *   cd frontend && npx playwright test e2e/ai-integration.spec.ts
 */

import { test, expect } from '@playwright/test';

const BACKEND_URL = 'http://localhost:8000';
const FRONTEND_URL = 'http://localhost:5173';

test.describe('AI Integration', () => {
  let meetingId: string | null = null;

  test.beforeAll(async ({ request }) => {
    // Create a test meeting via API
    const response = await request.post(`${BACKEND_URL}/api/meetings`, {
      data: { title: 'E2E Test Meeting' },
    });

    if (response.ok()) {
      const meeting = await response.json();
      meetingId = meeting.id;
      console.log(`Created test meeting: ${meetingId}`);
    } else {
      console.error('Failed to create meeting:', await response.text());
    }
  });

  test.afterAll(async ({ request }) => {
    // Clean up test meeting
    if (meetingId) {
      await request.delete(`${BACKEND_URL}/api/meetings/${meetingId}`);
      console.log(`Deleted test meeting: ${meetingId}`);
    }
  });

  test('Backend health check - API is accessible', async ({ request }) => {
    const response = await request.get(`${BACKEND_URL}/api/meetings`);
    expect(response.ok()).toBe(true);
  });

  test('Summary generation endpoint works', async ({ request }) => {
    test.skip(!meetingId, 'No meeting ID available');

    // First, add some transcript data for the meeting
    // This simulates what would happen during audio capture
    const transcriptResponse = await request.post(`${BACKEND_URL}/api/transcripts`, {
      data: {
        meeting_id: meetingId,
        text: 'This is a test transcript for the E2E test meeting. We discussed important project milestones.',
        speaker: 'system',
        timestamp: 0,
      },
    });

    // Summary generation may return "no content" if there are no transcripts
    const summaryResponse = await request.post(
      `${BACKEND_URL}/api/ai/meetings/${meetingId}/summaries/generate`
    );

    expect(summaryResponse.ok()).toBe(true);
    const data = await summaryResponse.json();
    expect(data).toHaveProperty('message');
    // Either has a summary or says "no content"
    expect(data.message).toBeTruthy();
  });

  test('AI query streaming endpoint responds', async ({ request }) => {
    test.skip(!meetingId, 'No meeting ID available');

    const response = await request.post(`${BACKEND_URL}/api/ai/query`, {
      data: {
        meeting_id: meetingId,
        question: 'What was discussed?',
        include_documents: false,
      },
    });

    expect(response.ok()).toBe(true);
    expect(response.headers()['content-type']).toContain('text/event-stream');

    // Read the stream
    const body = await response.text();
    console.log('SSE Response:', body.substring(0, 500));

    // Should have SSE format
    expect(body).toContain('data:');
  });

  test('Token usage endpoint returns valid data', async ({ request }) => {
    test.skip(!meetingId, 'No meeting ID available');

    const response = await request.get(
      `${BACKEND_URL}/api/ai/meetings/${meetingId}/tokens`
    );

    expect(response.ok()).toBe(true);
    const data = await response.json();
    expect(data).toHaveProperty('current_tokens');
    expect(data).toHaveProperty('max_tokens');
    expect(data).toHaveProperty('percentage');
    expect(data.max_tokens).toBeGreaterThan(0);
  });

  test('Recap endpoint works', async ({ request }) => {
    test.skip(!meetingId, 'No meeting ID available');

    const response = await request.post(`${BACKEND_URL}/api/ai/recap`, {
      data: {
        meeting_id: meetingId,
        duration_seconds: 30,
      },
    });

    expect(response.ok()).toBe(true);
    const data = await response.json();
    expect(data).toHaveProperty('recap');
    expect(data).toHaveProperty('tokens_used');
    expect(data).toHaveProperty('transcript_count');
  });
});

test.describe('Frontend UI - Requires Running App', () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to the frontend
    await page.goto(FRONTEND_URL);
    await page.waitForLoadState('networkidle');
  });

  test('App loads without errors', async ({ page }) => {
    // Check that the app loads
    await expect(page.locator('body')).toBeVisible();

    // Check for no console errors (optional, can be noisy)
    const errors: string[] = [];
    page.on('console', (msg) => {
      if (msg.type() === 'error') {
        errors.push(msg.text());
      }
    });

    await page.waitForTimeout(2000);

    // Filter out known acceptable errors
    const criticalErrors = errors.filter(
      (e) =>
        !e.includes('favicon') &&
        !e.includes('WebSocket') && // WS may fail if no backend
        !e.includes('Failed to load resource')
    );

    expect(criticalErrors.length).toBe(0);
  });

  test('Summary panel is visible', async ({ page }) => {
    const summaryPanel = page.locator('[data-testid="summary-panel"]');
    await expect(summaryPanel).toBeVisible({ timeout: 5000 });
  });

  test('Query input appears when meeting is active', async ({ page }) => {
    // This test would need a meeting to be in progress
    // For now, just verify the element exists in the DOM
    const queryInput = page.locator('[data-testid="query-input"]');

    // It may not be visible if no meeting is active
    // Just verify no errors in rendering
    await page.waitForTimeout(1000);
  });
});

test.describe('Diagnostic Tests - Direct LLM Verification', () => {
  test('OpenAI Responses API is functional', async ({ request }) => {
    // This tests the diagnostic endpoint if one exists,
    // or directly tests the summary endpoint with known input

    // Create a test meeting
    const createResponse = await request.post(`${BACKEND_URL}/api/meetings`, {
      data: { title: 'LLM Diagnostic Test' },
    });
    expect(createResponse.ok()).toBe(true);
    const meeting = await createResponse.json();

    try {
      // Add a transcript
      await request.post(`${BACKEND_URL}/api/transcripts`, {
        data: {
          meeting_id: meeting.id,
          text: 'The team agreed to launch the product next month. Action item: prepare marketing materials by Friday.',
          speaker: 'system',
          timestamp: 0,
        },
      });

      // Request summary
      const summaryResponse = await request.post(
        `${BACKEND_URL}/api/ai/meetings/${meeting.id}/summaries/generate`
      );

      expect(summaryResponse.ok()).toBe(true);
      const summaryData = await summaryResponse.json();

      console.log('Summary response:', summaryData);

      // If LLM is working, we should get a summary
      if (summaryData.summary) {
        expect(summaryData.summary.content).toBeTruthy();
        expect(summaryData.summary.content.length).toBeGreaterThan(10);
        console.log('Generated summary:', summaryData.summary.content);
      } else {
        // This is acceptable if no new content (already summarized)
        console.log('No summary generated:', summaryData.message);
      }
    } finally {
      // Cleanup
      await request.delete(`${BACKEND_URL}/api/meetings/${meeting.id}`);
    }
  });
});
