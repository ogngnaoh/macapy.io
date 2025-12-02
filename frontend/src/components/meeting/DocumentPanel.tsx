/**
 * DocumentPanel Component
 * Document upload and management for meeting context
 */

import { useState, useCallback } from 'react';
import { useStore } from '@/store';
import { documentsApi, Document } from '@/services/api';
import { cn, formatDate } from '@/lib/utils';
import { Button, Badge, DropZone, Spinner, EmptyState } from '@/components/common';

export function DocumentPanel() {
  const {
    meeting,
    documents,
    addDocument,
    removeDocument,
    setDocumentsUploading,
  } = useStore();

  const [isExpanded, setIsExpanded] = useState(false);
  const [deleteConfirm, setDeleteConfirm] = useState<number | null>(null);

  const handleUpload = useCallback(async (files: File[]) => {
    if (!meeting.current) return;

    setDocumentsUploading(true);
    try {
      for (const file of files) {
        const doc = await documentsApi.upload(meeting.current.id, file);
        addDocument(doc);
      }
    } catch (error) {
      console.error('Upload failed:', error);
    } finally {
      setDocumentsUploading(false);
    }
  }, [meeting.current, addDocument, setDocumentsUploading]);

  const handleDelete = useCallback(async (id: number) => {
    try {
      await documentsApi.delete(id);
      removeDocument(id);
      setDeleteConfirm(null);
    } catch (error) {
      console.error('Delete failed:', error);
    }
  }, [removeDocument]);

  const getFileIcon = (fileType: string): string => {
    switch (fileType.toLowerCase()) {
      case 'pdf': return '📄';
      case 'docx':
      case 'doc': return '📝';
      case 'txt': return '📃';
      case 'md': return '📑';
      default: return '📎';
    }
  };

  const isActive = meeting.status === 'recording' || meeting.status === 'paused';

  return (
    <div className="border-t border-border-default bg-bg-secondary">
      {/* Header */}
      <button
        onClick={() => setIsExpanded(!isExpanded)}
        className={cn(
          'w-full flex items-center justify-between px-4 py-2',
          'hover:bg-bg-tertiary transition-colors'
        )}
      >
        <div className="flex items-center gap-2">
          <span className="text-text-primary text-sm font-mono font-medium">
            Documents
          </span>
          <Badge variant="default">{documents.items.length}</Badge>
        </div>
        <span className="text-text-dim text-sm">
          {isExpanded ? '▼' : '▶'}
        </span>
      </button>

      {/* Expanded content */}
      {isExpanded && (
        <div className="px-4 pb-4 space-y-3">
          {/* Upload zone */}
          {isActive && (
            <DropZone
              onDrop={handleUpload}
              accept=".pdf,.docx,.txt,.md"
              maxSize={10 * 1024 * 1024}
              multiple
              disabled={documents.isUploading}
            />
          )}

          {/* Uploading indicator */}
          {documents.isUploading && (
            <div className="flex items-center gap-2 text-sm text-text-muted font-mono">
              <Spinner size="sm" />
              <span>Uploading...</span>
            </div>
          )}

          {/* Document list */}
          {documents.items.length === 0 ? (
            <EmptyState
              icon="📂"
              title="No documents uploaded"
              description="Upload PDF, DOCX, or TXT files to provide context for AI responses"
            />
          ) : (
            <div className="space-y-2">
              {documents.items.map((doc) => (
                <div
                  key={doc.id}
                  className={cn(
                    'flex items-center gap-3 p-3',
                    'bg-bg-tertiary border border-border-default rounded-terminal',
                    'text-sm font-mono'
                  )}
                >
                  {/* File icon */}
                  <span className="text-lg">{getFileIcon(doc.file_type)}</span>

                  {/* File info */}
                  <div className="flex-1 min-w-0">
                    <div className="text-text-primary truncate">
                      {doc.filename}
                    </div>
                    <div className="text-xs text-text-dim">
                      {doc.file_type.toUpperCase()} • {formatDate(doc.created_at)}
                    </div>
                  </div>

                  {/* Delete button */}
                  {isActive && (
                    deleteConfirm === doc.id ? (
                      <div className="flex items-center gap-1">
                        <Button
                          variant="danger"
                          size="sm"
                          onClick={() => handleDelete(doc.id)}
                        >
                          Confirm
                        </Button>
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => setDeleteConfirm(null)}
                        >
                          Cancel
                        </Button>
                      </div>
                    ) : (
                      <button
                        onClick={() => setDeleteConfirm(doc.id)}
                        className="text-text-dim hover:text-accent-error transition-colors"
                      >
                        &times;
                      </button>
                    )
                  )}
                </div>
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

export default DocumentPanel;
