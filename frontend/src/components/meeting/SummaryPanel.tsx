/**
 * SummaryPanel Component
 * Displays rolling AI-generated summaries with manual trigger
 */

import { useState, useCallback } from 'react';
import { useStore } from '@/store';
import { aiApi } from '@/services/api';
import { cn } from '@/lib/utils';
import { Button, Spinner, Badge } from '@/components/common';

export function SummaryPanel() {
  const { meeting, summary, addSummary, setSummaryLoading } = useStore();
  const [isExpanded, setIsExpanded] = useState<number | null>(null);

  const [error, setError] = useState<string | null>(null);

  const handleGenerateSummary = useCallback(async () => {
    if (!meeting.current) return;

    setSummaryLoading(true);
    setError(null);

    try {
      const response = await aiApi.generateSummary(meeting.current.id);
      if (response.summary) {
        addSummary(response.summary);
      } else if (response.message.includes('No new content')) {
        setError('No new content to summarize');
      }
    } catch (error) {
      console.error('Failed to generate summary:', error);
      const message = error instanceof Error ? error.message : 'Failed to generate summary';
      setError(message);
    } finally {
      setSummaryLoading(false);
    }
  }, [meeting.current, addSummary, setSummaryLoading]);

  const formatTime = (dateString: string | null): string => {
    if (!dateString) return '--:--';
    const date = new Date(dateString);
    return date.toLocaleTimeString('en-US', {
      hour: '2-digit',
      minute: '2-digit',
    });
  };

  const isRecording = meeting.status === 'recording' || meeting.status === 'paused';

  return (
    <div data-testid="summary-panel" className="flex flex-col h-full bg-bg-secondary border-l border-border-default">
      {/* Header */}
      <div className="flex items-center justify-between px-4 py-3 border-b border-border-default">
        <div className="flex items-center gap-2">
          <span className="text-text-primary text-sm font-mono font-medium">
            Summaries
          </span>
          <Badge variant="info">{summary.items.length}</Badge>
        </div>
        {isRecording && (
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

      {/* Error Message */}
      {error && (
        <div className="mx-2 mt-2 p-2 rounded-terminal bg-accent-error/10 border border-accent-error/50">
          <span className="text-accent-error text-xs font-mono">{error}</span>
        </div>
      )}

      {/* Summary List */}
      <div className="flex-1 overflow-y-auto p-2 space-y-2">
        {summary.items.length === 0 ? (
          <div className="flex flex-col items-center justify-center h-full text-center p-4">
            <span className="text-text-dim text-sm font-mono">
              No summaries yet
            </span>
            <span className="text-text-dim text-xs font-mono mt-1">
              Summaries are generated every 30 seconds
            </span>
          </div>
        ) : (
          summary.items.map((item, index) => (
            <div
              key={item.id}
              className={cn(
                'bg-bg-tertiary border border-border-default rounded-terminal p-3',
                'transition-all duration-150 cursor-pointer',
                'hover:border-text-primary/30',
                isExpanded === item.id && 'border-text-primary/50'
              )}
              onClick={() => setIsExpanded(isExpanded === item.id ? null : item.id)}
            >
              {/* Summary Header */}
              <div className="flex items-center justify-between mb-2">
                <span className="text-xs text-text-dim font-mono">
                  [{formatTime(item.start_time)} - {formatTime(item.end_time)}]
                </span>
                <Badge variant="success" className="text-[10px]">
                  #{index + 1}
                </Badge>
              </div>

              {/* Summary Content */}
              <div
                className={cn(
                  'text-sm text-text-primary font-mono whitespace-pre-wrap',
                  !isExpanded || isExpanded !== item.id
                    ? 'line-clamp-3'
                    : ''
                )}
              >
                {item.content}
              </div>

              {/* Expand/Collapse indicator */}
              {item.content.length > 150 && (
                <div className="mt-2 text-xs text-text-dim font-mono">
                  {isExpanded === item.id ? '[ collapse ]' : '[ expand ]'}
                </div>
              )}
            </div>
          ))
        )}
      </div>

      {/* Footer - Auto-summary indicator */}
      {isRecording && (
        <div className="px-4 py-2 border-t border-border-default">
          <div className="flex items-center gap-2 text-xs text-text-dim font-mono">
            <Spinner size="sm" variant="dots" />
            <span>Auto-summarizing every 30s</span>
          </div>
        </div>
      )}
    </div>
  );
}

export default SummaryPanel;
