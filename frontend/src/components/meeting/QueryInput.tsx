/**
 * QueryInput Component
 * Terminal-style input for user questions with streaming AI responses
 */

import { useState, useCallback, useRef, useEffect, KeyboardEvent } from 'react';
import { useStore } from '@/store';
import { aiApi } from '@/services/api';
import { cn } from '@/lib/utils';
import { Spinner } from '@/components/common';

export function QueryInput() {
  const {
    meeting,
    query,
    setQueryInput,
    addQueryExchange,
    setQueryLoading,
  } = useStore();

  const [streamingResponse, setStreamingResponse] = useState('');
  const inputRef = useRef<HTMLInputElement>(null);
  const responseContainerRef = useRef<HTMLDivElement>(null);

  // Auto-scroll responses
  useEffect(() => {
    if (responseContainerRef.current) {
      responseContainerRef.current.scrollTop = responseContainerRef.current.scrollHeight;
    }
  }, [streamingResponse, query.exchanges]);

  const handleSubmit = useCallback(async () => {
    if (!meeting.current || !query.input.trim() || query.isLoading) return;

    const question = query.input.trim();
    setQueryInput('');
    setQueryLoading(true);
    setStreamingResponse('');

    try {
      let response = '';
      for await (const chunk of aiApi.streamQuery(meeting.current.id, question)) {
        response += chunk;
        setStreamingResponse(response);
      }

      // Add to exchanges
      addQueryExchange({
        id: Date.now().toString(),
        question,
        answer: response,
        timestamp: new Date().toISOString(),
      });
      setStreamingResponse('');
    } catch (error) {
      console.error('Query failed:', error);
      setStreamingResponse(`Error: ${error instanceof Error ? error.message : 'Query failed'}`);
    } finally {
      setQueryLoading(false);
    }
  }, [meeting.current, query.input, query.isLoading, setQueryInput, setQueryLoading, addQueryExchange]);

  const handleKeyDown = useCallback((e: KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      handleSubmit();
    }
  }, [handleSubmit]);

  // Note: Cmd+K focus is handled globally by useKeyboardShortcuts hook

  const isActive = meeting.status === 'recording' || meeting.status === 'paused';

  if (!isActive) return null;

  return (
    <div className="border-t border-border-default bg-bg-secondary">
      {/* Previous Q&A exchanges */}
      {(query.exchanges.length > 0 || streamingResponse) && (
        <div
          ref={responseContainerRef}
          className="max-h-72 overflow-y-auto p-4 space-y-4 border-b border-border-default bg-bg-tertiary/30"
        >
          {query.exchanges.map((exchange) => (
            <div
              key={exchange.id}
              className="p-3 rounded-terminal bg-bg-primary border border-border-default space-y-2"
            >
              <div className="flex items-start gap-2">
                <span className="text-accent-success font-mono text-xs font-bold shrink-0">Q:</span>
                <span className="text-text-primary text-sm font-mono">{exchange.question}</span>
              </div>
              <div className="flex items-start gap-2 pl-4">
                <span className="text-accent-cyan font-mono text-xs font-bold shrink-0">A:</span>
                <span className="text-text-muted text-sm font-mono whitespace-pre-wrap leading-relaxed">
                  {exchange.answer}
                </span>
              </div>
            </div>
          ))}

          {/* Streaming response */}
          {streamingResponse && (
            <div className="p-3 rounded-terminal bg-bg-primary border border-accent-cyan/50 space-y-2">
              <div className="flex items-start gap-2">
                <span className="text-accent-success font-mono text-xs font-bold shrink-0">Q:</span>
                <span className="text-text-primary text-sm font-mono">{query.input || '...'}</span>
              </div>
              <div className="flex items-start gap-2 pl-4">
                <span className="text-accent-cyan font-mono text-xs font-bold shrink-0">A:</span>
                <span className="text-text-muted text-sm font-mono whitespace-pre-wrap leading-relaxed">
                  {streamingResponse}
                  <span className="inline-block w-1.5 h-3 bg-accent-cyan animate-blink ml-0.5" />
                </span>
              </div>
            </div>
          )}
        </div>
      )}

      {/* Input area */}
      <div className="flex items-center gap-2 px-4 py-3">
        <span className="text-accent-success font-mono font-bold">&gt;</span>
        <input
          ref={inputRef}
          type="text"
          data-testid="query-input"
          value={query.input}
          onChange={(e) => setQueryInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Ask a question about the meeting... (⌘+K to focus)"
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
            onClick={handleSubmit}
            disabled={!query.input.trim()}
            className={cn(
              'px-3 py-1 rounded-terminal text-xs font-mono',
              'transition-all duration-150',
              query.input.trim()
                ? 'bg-text-primary/10 text-text-primary hover:bg-text-primary/20'
                : 'bg-bg-tertiary text-text-dim cursor-not-allowed'
            )}
          >
            Send (⌘↵)
          </button>
        )}
      </div>
    </div>
  );
}

export default QueryInput;
