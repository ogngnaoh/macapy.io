/**
 * SuggestionsPanel Component
 * Dashboard panel displaying AI-generated response suggestions for detected questions
 * Replaces the floating popup SuggestionNotification with a stacked section view
 */

import { useState, useCallback, useRef, useEffect } from 'react';
import { useStore, type SuggestionData } from '@/store';
import { cn, copyToClipboard } from '@/lib/utils';
import { Badge } from '@/components/common';

interface SuggestionItemProps {
  suggestion: SuggestionData;
  isActive: boolean;
  onDismiss?: () => void;
}

function SuggestionItem({ suggestion, isActive, onDismiss }: SuggestionItemProps) {
  const [copiedIndex, setCopiedIndex] = useState<number | null>(null);
  const [isExpanded, setIsExpanded] = useState(isActive);

  const handleCopy = useCallback(async (text: string, index: number, e: React.MouseEvent) => {
    e.stopPropagation();
    const success = await copyToClipboard(text);
    if (success) {
      setCopiedIndex(index);
      setTimeout(() => setCopiedIndex(null), 2000);
    }
  }, []);

  return (
    <div
      className={cn(
        'border rounded-terminal transition-all duration-200',
        isActive
          ? 'border-accent-cyan/50 bg-bg-secondary'
          : 'border-border-default bg-bg-tertiary/50'
      )}
    >
      {/* Header - clickable to expand/collapse */}
      <button
        onClick={() => setIsExpanded(!isExpanded)}
        className="w-full flex items-center justify-between px-3 py-2 text-left hover:bg-bg-tertiary/50 transition-colors"
      >
        <div className="flex items-center gap-2 min-w-0 flex-1">
          {isActive && (
            <span className="w-1.5 h-1.5 bg-accent-cyan rounded-full animate-pulse shrink-0" />
          )}
          <span className="text-xs text-text-dim font-mono shrink-0">Q:</span>
          <span className="text-sm text-text-primary font-mono truncate">
            {suggestion.question}
          </span>
        </div>
        <div className="flex items-center gap-2 shrink-0 ml-2">
          <span className="text-xs text-text-dim">
            {suggestion.suggestions.length} response{suggestion.suggestions.length !== 1 ? 's' : ''}
          </span>
          <span className={cn(
            'text-text-dim transition-transform',
            isExpanded ? 'rotate-180' : ''
          )}>
            ▼
          </span>
        </div>
      </button>

      {/* Expanded content - response suggestions */}
      {isExpanded && (
        <div className="px-3 pb-3 space-y-2 border-t border-border-default">
          <span className="text-xs text-text-dim font-mono block pt-2">
            Suggested responses:
          </span>
          {suggestion.suggestions.map((response, index) => (
            <button
              key={index}
              onClick={(e) => handleCopy(response, index, e)}
              className={cn(
                'w-full text-left p-2.5 rounded-terminal',
                'bg-bg-primary border border-border-default',
                'text-sm text-text-muted font-mono',
                'transition-all duration-150',
                'hover:border-text-primary/50 hover:bg-bg-secondary',
                copiedIndex === index && 'border-accent-success bg-accent-success/10'
              )}
            >
              <div className="flex items-start gap-2">
                <span className="text-text-dim text-xs shrink-0">
                  {index + 1}.
                </span>
                <span className="flex-1 leading-relaxed">
                  {response}
                </span>
              </div>
              {copiedIndex === index && (
                <span className="text-xs text-accent-success mt-1 block">
                  Copied!
                </span>
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

export function SuggestionsPanel() {
  const { suggestion, dismissActiveSuggestion, clearSuggestions } = useStore();
  const scrollRef = useRef<HTMLDivElement>(null);

  // Combine active and queue into a single list for display
  const allSuggestions: SuggestionData[] = suggestion.active
    ? [suggestion.active, ...suggestion.queue]
    : suggestion.queue;

  // Auto-scroll to top when new suggestion arrives
  useEffect(() => {
    if (suggestion.active && scrollRef.current) {
      scrollRef.current.scrollTop = 0;
    }
  }, [suggestion.active?.id]);

  const hasSuggestions = allSuggestions.length > 0;

  return (
    <div
      data-testid="suggestions-panel"
      className="flex-1 flex flex-col min-h-0 bg-bg-primary"
    >
      {/* Panel Header */}
      <div className="px-4 py-2.5 border-b border-border-default flex items-center justify-between">
        <div className="flex items-center gap-2">
          <span className="text-text-muted text-sm">AI Suggestions</span>
          {hasSuggestions && (
            <Badge variant="info">{allSuggestions.length}</Badge>
          )}
          {suggestion.active && (
            <span className="w-1.5 h-1.5 bg-accent-cyan rounded-full animate-pulse" />
          )}
        </div>

        {hasSuggestions && (
          <button
            onClick={clearSuggestions}
            className="text-xs text-text-dim hover:text-text-muted transition-colors"
          >
            Clear all
          </button>
        )}
      </div>

      {/* Scrollable Content */}
      <div
        ref={scrollRef}
        className="flex-1 overflow-y-auto p-4 space-y-3 custom-scrollbar"
      >
        {!hasSuggestions ? (
          <div className="flex items-center justify-center h-full">
            <div className="text-center">
              <span className="text-2xl mb-2 block">💡</span>
              <span className="text-text-dim text-sm italic block">
                AI suggestions will appear here
              </span>
              <span className="text-text-dim text-xs block mt-1">
                when questions are detected
              </span>
            </div>
          </div>
        ) : (
          allSuggestions.map((sugg, index) => (
            <SuggestionItem
              key={sugg.id}
              suggestion={sugg}
              isActive={index === 0 && suggestion.active?.id === sugg.id}
              onDismiss={index === 0 ? dismissActiveSuggestion : undefined}
            />
          ))
        )}
      </div>

      {/* Footer */}
      {hasSuggestions && (
        <div className="px-4 py-2 border-t border-border-default bg-bg-secondary">
          <span className="text-text-dim text-xs">
            Click a response to copy to clipboard
          </span>
        </div>
      )}
    </div>
  );
}

export default SuggestionsPanel;
