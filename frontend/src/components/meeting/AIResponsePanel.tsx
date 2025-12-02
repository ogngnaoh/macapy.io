/**
 * AIResponsePanel Component
 * Unified panel displaying all AI responses (summaries, suggestions, queries)
 * with integrated chat-style query input
 */

import { useState, useCallback, useRef, useEffect, KeyboardEvent } from 'react';
import { useStore, type AIResponseItem, type AIResponseFilter } from '@/store';
import { aiApi } from '@/services/api';
import { cn } from '@/lib/utils';
import { Button, Spinner, Badge } from '@/components/common';

const FILTER_OPTIONS: { value: AIResponseFilter; label: string }[] = [
  { value: 'all', label: 'All' },
  { value: 'summary', label: 'Summaries' },
  { value: 'suggestion', label: 'Suggestions' },
  { value: 'query', label: 'Queries' },
];

export function AIResponsePanel() {
  const {
    meeting,
    aiResponses,
    query,
    summary,
    addAIResponse,
    setAIFilter,
    setQueryInput,
    addQueryExchange,
    setQueryLoading,
    addSummary,
    setSummaryLoading,
  } = useStore();

  const [streamingResponse, setStreamingResponse] = useState('');
  const [currentQuestion, setCurrentQuestion] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);
  const feedRef = useRef<HTMLDivElement>(null);

  // Auto-scroll feed when new items arrive
  useEffect(() => {
    if (feedRef.current) {
      feedRef.current.scrollTop = feedRef.current.scrollHeight;
    }
  }, [aiResponses.items, streamingResponse]);

  // Filter items based on selected filter
  const filteredItems = aiResponses.items.filter((item) => {
    if (aiResponses.filter === 'all') return true;
    if (aiResponses.filter === 'summary') return item.type === 'summary';
    if (aiResponses.filter === 'suggestion') return item.type === 'suggestion';
    if (aiResponses.filter === 'query') return item.type === 'query_response';
    return true;
  });

  const handleGenerateSummary = useCallback(async () => {
    if (!meeting.current) return;

    setSummaryLoading(true);
    try {
      const response = await aiApi.generateSummary(meeting.current.id);
      if (response.summary) {
        addSummary(response.summary);
        // Also add to unified feed
        addAIResponse({
          id: `summary-${response.summary.id}`,
          type: 'summary',
          content: response.summary.content,
          timestamp: response.summary.created_at,
          metadata: {
            timeRange: {
              start: response.summary.start_time,
              end: response.summary.end_time,
            },
          },
        });
      }
    } catch (error) {
      console.error('Failed to generate summary:', error);
    } finally {
      setSummaryLoading(false);
    }
  }, [meeting.current, addSummary, setSummaryLoading, addAIResponse]);

  const handleSubmitQuery = useCallback(async () => {
    if (!meeting.current || !query.input.trim() || query.isLoading) return;

    const question = query.input.trim();
    setCurrentQuestion(question);
    setQueryInput('');
    setQueryLoading(true);
    setStreamingResponse('');

    try {
      let response = '';
      for await (const chunk of aiApi.streamQuery(meeting.current.id, question)) {
        response += chunk;
        setStreamingResponse(response);
      }

      // Add to query exchanges
      addQueryExchange({
        id: Date.now().toString(),
        question,
        answer: response,
        timestamp: new Date().toISOString(),
      });

      // Also add to unified feed
      addAIResponse({
        id: `query-${Date.now()}`,
        type: 'query_response',
        content: response,
        timestamp: new Date().toISOString(),
        metadata: { question },
      });

      setStreamingResponse('');
      setCurrentQuestion('');
    } catch (error) {
      console.error('Query failed:', error);
      setStreamingResponse(`Error: ${error instanceof Error ? error.message : 'Query failed'}`);
    } finally {
      setQueryLoading(false);
    }
  }, [meeting.current, query.input, query.isLoading, setQueryInput, setQueryLoading, addQueryExchange, addAIResponse]);

  const handleKeyDown = useCallback(
    (e: KeyboardEvent<HTMLInputElement>) => {
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        handleSubmitQuery();
      }
    },
    [handleSubmitQuery]
  );

  const formatTime = (dateString: string): string => {
    const date = new Date(dateString);
    return date.toLocaleTimeString('en-US', {
      hour: '2-digit',
      minute: '2-digit',
    });
  };

  const formatTimeRange = (start: string | null, end: string | null): string => {
    const startTime = start ? formatTime(start) : '--:--';
    const endTime = end ? formatTime(end) : '--:--';
    return `[${startTime} - ${endTime}]`;
  };

  const copyToClipboard = (text: string) => {
    navigator.clipboard.writeText(text);
  };

  const isActive = meeting.status === 'recording' || meeting.status === 'paused';

  const renderResponseItem = (item: AIResponseItem) => {
    switch (item.type) {
      case 'summary':
        return (
          <div
            key={item.id}
            className="p-3 rounded-terminal bg-bg-tertiary border border-border-default space-y-2"
          >
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Badge variant="success" className="text-[10px]">
                  SUMMARY
                </Badge>
                <span className="text-xs text-text-dim font-mono">
                  {item.metadata?.timeRange && formatTimeRange(item.metadata.timeRange.start, item.metadata.timeRange.end)}
                </span>
              </div>
              <span className="text-xs text-text-dim font-mono">{formatTime(item.timestamp)}</span>
            </div>
            <div className="text-sm text-text-primary font-mono whitespace-pre-wrap">
              {item.content}
            </div>
          </div>
        );

      case 'suggestion':
        return (
          <div
            key={item.id}
            className="p-3 rounded-terminal bg-bg-tertiary border border-accent-warning/30 space-y-2"
          >
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Badge variant="warning" className="text-[10px]">
                  SUGGESTION
                </Badge>
              </div>
              <span className="text-xs text-text-dim font-mono">{formatTime(item.timestamp)}</span>
            </div>
            {item.metadata?.question && (
              <div className="text-xs text-text-dim font-mono mb-2">
                Detected: "{item.metadata.question}"
              </div>
            )}
            <div className="space-y-1">
              {item.metadata?.suggestions?.map((suggestion, idx) => (
                <div
                  key={idx}
                  onClick={() => copyToClipboard(suggestion)}
                  className="p-2 rounded bg-bg-primary border border-border-default cursor-pointer hover:border-accent-warning/50 transition-colors"
                >
                  <span className="text-xs text-accent-warning font-mono mr-2">{idx + 1}.</span>
                  <span className="text-sm text-text-primary font-mono">{suggestion}</span>
                </div>
              ))}
            </div>
          </div>
        );

      case 'query_response':
        return (
          <div
            key={item.id}
            className="p-3 rounded-terminal bg-bg-primary border border-border-default space-y-2"
          >
            <div className="flex items-center justify-between">
              <Badge variant="info" className="text-[10px]">
                Q&A
              </Badge>
              <span className="text-xs text-text-dim font-mono">{formatTime(item.timestamp)}</span>
            </div>
            {item.metadata?.question && (
              <div className="flex items-start gap-2">
                <span className="text-accent-success font-mono text-xs font-bold shrink-0">Q:</span>
                <span className="text-text-primary text-sm font-mono">{item.metadata.question}</span>
              </div>
            )}
            <div className="flex items-start gap-2 pl-4">
              <span className="text-accent-cyan font-mono text-xs font-bold shrink-0">A:</span>
              <span className="text-text-muted text-sm font-mono whitespace-pre-wrap leading-relaxed">
                {item.content}
              </span>
            </div>
          </div>
        );

      default:
        return null;
    }
  };

  return (
    <div
      data-testid="ai-response-panel"
      className="flex flex-col h-full bg-bg-secondary border-l border-border-default"
    >
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-3 border-b border-border-default">
        <div className="flex items-center gap-2">
          <span className="text-text-primary text-sm font-mono font-medium">AI Assistant</span>
          <Badge variant="info">{filteredItems.length}</Badge>
        </div>
        {isActive && (
          <Button
            variant="primary"
            size="sm"
            onClick={handleGenerateSummary}
            disabled={summary.isLoading}
            isLoading={summary.isLoading}
          >
            {summary.isLoading ? 'Generating...' : 'Summarize Now'}
          </Button>
        )}
      </div>

      {/* Filter Tabs */}
      <div className="flex items-center gap-1 px-4 py-2 border-b border-border-default bg-bg-tertiary/50">
        {FILTER_OPTIONS.map((option) => (
          <button
            key={option.value}
            onClick={() => setAIFilter(option.value)}
            className={cn(
              'px-3 py-1 rounded-terminal text-xs font-mono transition-colors',
              aiResponses.filter === option.value
                ? 'bg-text-primary/10 text-text-primary'
                : 'text-text-dim hover:text-text-muted hover:bg-bg-primary'
            )}
          >
            {option.label}
          </button>
        ))}
      </div>

      {/* Response Feed */}
      <div ref={feedRef} className="flex-1 overflow-y-auto p-3 space-y-3">
        {filteredItems.length === 0 && !streamingResponse ? (
          <div className="flex flex-col items-center justify-center h-full text-center p-4">
            <span className="text-text-dim text-sm font-mono">No AI responses yet</span>
            <span className="text-text-dim text-xs font-mono mt-1">
              {isActive
                ? 'Summaries appear every 30s. Ask questions below.'
                : 'Start a meeting to get AI assistance'}
            </span>
          </div>
        ) : (
          <>
            {/* Rendered items (oldest first for chat flow) */}
            {[...filteredItems].reverse().map(renderResponseItem)}

            {/* Streaming response */}
            {streamingResponse && (
              <div className="p-3 rounded-terminal bg-bg-primary border border-accent-cyan/50 space-y-2">
                <div className="flex items-center justify-between">
                  <Badge variant="info" className="text-[10px]">
                    Q&A
                  </Badge>
                  <Spinner size="sm" />
                </div>
                {currentQuestion && (
                  <div className="flex items-start gap-2">
                    <span className="text-accent-success font-mono text-xs font-bold shrink-0">Q:</span>
                    <span className="text-text-primary text-sm font-mono">{currentQuestion}</span>
                  </div>
                )}
                <div className="flex items-start gap-2 pl-4">
                  <span className="text-accent-cyan font-mono text-xs font-bold shrink-0">A:</span>
                  <span className="text-text-muted text-sm font-mono whitespace-pre-wrap leading-relaxed">
                    {streamingResponse}
                    <span className="inline-block w-1.5 h-3 bg-accent-cyan animate-blink ml-0.5" />
                  </span>
                </div>
              </div>
            )}
          </>
        )}
      </div>

      {/* Query Input (integrated at bottom) */}
      {isActive && (
        <div className="border-t border-border-default bg-bg-primary">
          <div className="flex items-center gap-2 px-4 py-3">
            <span className="text-accent-success font-mono font-bold">&gt;</span>
            <input
              ref={inputRef}
              type="text"
              data-testid="query-input"
              value={query.input}
              onChange={(e) => setQueryInput(e.target.value)}
              onKeyDown={handleKeyDown}
              placeholder="Ask about the meeting... (⌘+K to focus, ⌘+↵ to send)"
              disabled={query.isLoading}
              className={cn(
                'flex-1 bg-transparent border-none outline-none',
                'text-text-primary text-sm font-mono',
                'placeholder:text-text-dim',
                'disabled:opacity-50'
              )}
            />
            {query.isLoading ? (
              <Spinner size="sm" />
            ) : (
              <button
                onClick={handleSubmitQuery}
                disabled={!query.input.trim()}
                className={cn(
                  'px-3 py-1 rounded-terminal text-xs font-mono',
                  'transition-all duration-150',
                  query.input.trim()
                    ? 'bg-text-primary/10 text-text-primary hover:bg-text-primary/20'
                    : 'bg-bg-tertiary text-text-dim cursor-not-allowed'
                )}
              >
                Send
              </button>
            )}
          </div>
        </div>
      )}

      {/* Auto-summary indicator */}
      {isActive && (
        <div className="px-4 py-2 border-t border-border-default bg-bg-tertiary/50">
          <div className="flex items-center gap-2 text-xs text-text-dim font-mono">
            <Spinner size="sm" variant="dots" />
            <span>Auto-summarizing every 30s</span>
          </div>
        </div>
      )}
    </div>
  );
}

export default AIResponsePanel;
