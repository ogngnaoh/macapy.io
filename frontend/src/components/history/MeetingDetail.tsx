/**
 * MeetingDetail Component
 * Detailed view of a completed meeting with unified transcript and summaries
 */

import { useEffect, useState } from 'react';
import { Meeting, Transcript, Summary, transcriptsApi, aiApi } from '@/services/api';
import { cn, formatDate, formatTimestamp, formatDuration } from '@/lib/utils';
import { Badge, Spinner, EmptyState } from '@/components/common';

export interface MeetingDetailProps {
  meeting: Meeting;
}

export function MeetingDetail({ meeting }: MeetingDetailProps) {
  const [transcripts, setTranscripts] = useState<Transcript[]>([]);
  const [summaries, setSummaries] = useState<Summary[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [activeTab, setActiveTab] = useState<'transcript' | 'summaries'>('transcript');

  useEffect(() => {
    async function loadData() {
      setIsLoading(true);
      try {
        const [transcriptsData, summariesData] = await Promise.all([
          transcriptsApi.list(meeting.id),
          aiApi.getSummaries(meeting.id),
        ]);
        setTranscripts(transcriptsData);
        setSummaries(summariesData);
      } catch (error) {
        console.error('Failed to load meeting details:', error);
      } finally {
        setIsLoading(false);
      }
    }
    loadData();
  }, [meeting.id]);

  const duration = meeting.end_time
    ? Math.floor((new Date(meeting.end_time).getTime() - new Date(meeting.start_time).getTime()) / 1000)
    : 0;

  if (isLoading) {
    return (
      <div className="flex items-center justify-center h-full">
        <Spinner size="lg" />
      </div>
    );
  }

  return (
    <div className="flex flex-col h-full">
      {/* Header */}
      <div className="px-4 py-3 border-b border-border-default bg-bg-secondary">
        <h2 className="text-text-primary text-lg font-mono font-medium mb-1">
          {meeting.title || 'Untitled Meeting'}
        </h2>
        <div className="flex items-center gap-3 text-xs text-text-dim font-mono">
          <span>{formatDate(meeting.start_time)}</span>
          {duration > 0 && (
            <>
              <span className="text-border-default">•</span>
              <span>{formatDuration(duration)}</span>
            </>
          )}
          <span className="text-border-default">•</span>
          <Badge variant="success">{meeting.status}</Badge>
        </div>
      </div>

      {/* Tabs */}
      <div className="flex border-b border-border-default bg-bg-secondary">
        <button
          onClick={() => setActiveTab('transcript')}
          className={cn(
            'px-4 py-2 text-sm font-mono transition-colors',
            activeTab === 'transcript'
              ? 'text-text-primary border-b-2 border-text-primary'
              : 'text-text-muted hover:text-text-primary'
          )}
        >
          Transcript ({transcripts.length})
        </button>
        <button
          onClick={() => setActiveTab('summaries')}
          className={cn(
            'px-4 py-2 text-sm font-mono transition-colors',
            activeTab === 'summaries'
              ? 'text-text-primary border-b-2 border-text-primary'
              : 'text-text-muted hover:text-text-primary'
          )}
        >
          Summaries ({summaries.length})
        </button>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-hidden">
        {activeTab === 'transcript' ? (
          transcripts.length === 0 ? (
            <EmptyState
              icon="📝"
              title="No transcript"
              description="This meeting has no transcript recorded"
            />
          ) : (
            <div className="h-full overflow-y-auto">
              {/* Unified transcript header */}
              <div className="px-4 py-2 border-b border-border-default bg-bg-tertiary sticky top-0">
                <span className="text-xs text-text-muted font-mono">
                  Meeting Transcript ({transcripts.length} segments)
                </span>
              </div>

              {/* Unified transcript list */}
              <div className="p-2">
                {transcripts.map((t) => (
                  <div
                    key={t.id}
                    className="group px-3 py-2.5 hover:bg-bg-tertiary/30 transition-colors border-b border-border-default/50"
                  >
                    <div className="flex items-start gap-3">
                      <span className="text-xs text-text-dim font-mono shrink-0 pt-0.5 opacity-60 group-hover:opacity-100 transition-opacity">
                        {formatTimestamp(t.timestamp)}
                      </span>
                      <p className="text-sm text-text-primary font-mono flex-1">
                        {t.text}
                      </p>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )
        ) : summaries.length === 0 ? (
          <EmptyState
            icon="📋"
            title="No summaries"
            description="No summaries were generated for this meeting"
          />
        ) : (
          <div className="p-4 space-y-4 overflow-y-auto h-full">
            {summaries.map((summary, index) => (
              <div
                key={summary.id}
                className="bg-bg-tertiary border border-border-default rounded-terminal p-4"
              >
                <div className="flex items-center justify-between mb-2">
                  <Badge variant="success">Summary #{index + 1}</Badge>
                  <span className="text-xs text-text-dim font-mono">
                    {formatDate(summary.created_at)}
                  </span>
                </div>
                <pre className="text-sm text-text-primary font-mono whitespace-pre-wrap">
                  {summary.content}
                </pre>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

export default MeetingDetail;
