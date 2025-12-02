/**
 * HistoryView Component
 * Main view for browsing and managing past meetings
 */

import { useEffect, useCallback, useMemo } from 'react';
import { useStore } from '@/store';
import { meetingsApi, Meeting } from '@/services/api';
import { cn } from '@/lib/utils';
import { SearchBar } from './SearchBar';
import { MeetingList } from './MeetingList';
import { MeetingDetail } from './MeetingDetail';
import { EmptyState, Button, Spinner, Dialog, DialogContent, DialogFooter, DialogClose } from '@/components/common';
import { useState } from 'react';

export function HistoryView() {
  const {
    history,
    setHistoryMeetings,
    setSelectedHistoryMeeting,
    setHistorySearchQuery,
    setHistoryLoading,
  } = useStore();

  const [deleteConfirm, setDeleteConfirm] = useState<Meeting | null>(null);

  // Load meetings on mount
  useEffect(() => {
    async function loadMeetings() {
      setHistoryLoading(true);
      try {
        const meetings = await meetingsApi.list(0, 100);
        // Only show completed meetings in history
        const completedMeetings = meetings.filter((m) => m.status === 'COMPLETED');
        setHistoryMeetings(completedMeetings);
      } catch (error) {
        console.error('Failed to load meetings:', error);
      } finally {
        setHistoryLoading(false);
      }
    }
    loadMeetings();
  }, [setHistoryMeetings, setHistoryLoading]);

  // Filter meetings by search query
  const filteredMeetings = useMemo(() => {
    if (!history.searchQuery.trim()) {
      return history.meetings;
    }
    const query = history.searchQuery.toLowerCase();
    return history.meetings.filter(
      (m) =>
        m.title?.toLowerCase().includes(query) ||
        m.platform?.toLowerCase().includes(query)
    );
  }, [history.meetings, history.searchQuery]);

  const handleSelect = useCallback(
    (meeting: Meeting) => {
      setSelectedHistoryMeeting(meeting);
    },
    [setSelectedHistoryMeeting]
  );

  const handleDelete = useCallback(async () => {
    if (!deleteConfirm) return;

    try {
      await meetingsApi.delete(deleteConfirm.id);
      setHistoryMeetings(history.meetings.filter((m) => m.id !== deleteConfirm.id));
      if (history.selected?.id === deleteConfirm.id) {
        setSelectedHistoryMeeting(null);
      }
      setDeleteConfirm(null);
    } catch (error) {
      console.error('Failed to delete meeting:', error);
    }
  }, [deleteConfirm, history.meetings, history.selected, setHistoryMeetings, setSelectedHistoryMeeting]);

  return (
    <div data-testid="history-view" className="flex-1 flex min-h-0 bg-bg-primary">
      {/* Left Panel: Search + List */}
      <div className="w-80 flex flex-col border-r border-border-default">
        {/* Header */}
        <div className="px-4 py-3 border-b border-border-default bg-bg-secondary">
          <h2 className="text-text-primary text-sm font-mono font-medium mb-3">
            Meeting History
          </h2>
          <SearchBar
            value={history.searchQuery}
            onChange={setHistorySearchQuery}
            resultCount={filteredMeetings.length}
            placeholder="Search meetings..."
          />
        </div>

        {/* Meeting List */}
        <div className="flex-1 min-h-0">
          <MeetingList
            meetings={filteredMeetings}
            selectedId={history.selected?.id || null}
            onSelect={handleSelect}
            onDelete={(id) => {
              const meeting = history.meetings.find((m) => m.id === id);
              if (meeting) setDeleteConfirm(meeting);
            }}
            isLoading={history.isLoading}
          />
        </div>
      </div>

      {/* Right Panel: Meeting Detail */}
      <div className="flex-1 min-h-0">
        {history.selected ? (
          <MeetingDetail meeting={history.selected} />
        ) : (
          <EmptyState
            icon="📂"
            title="Select a meeting"
            description="Choose a meeting from the list to view its details"
          />
        )}
      </div>

      {/* Delete Confirmation Dialog */}
      <Dialog open={!!deleteConfirm} onOpenChange={() => setDeleteConfirm(null)}>
        <DialogContent title="Delete Meeting">
          <p className="text-sm text-text-muted font-mono">
            Are you sure you want to delete "{deleteConfirm?.title || 'Untitled Meeting'}"?
            This action cannot be undone.
          </p>
          <DialogFooter>
            <DialogClose>
              <Button variant="ghost">Cancel</Button>
            </DialogClose>
            <Button variant="danger" onClick={handleDelete}>
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}

export default HistoryView;
