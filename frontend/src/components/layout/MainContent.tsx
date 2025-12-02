export function MainContent() {
  return (
    <main className="flex-1 flex flex-col overflow-hidden">
      {/* Content header */}
      <header className="h-14 px-6 flex items-center justify-between border-b border-border-default bg-bg-secondary/50">
        <div>
          <h1 className="text-lg font-semibold text-text-primary">Meeting Room</h1>
          <p className="text-xs text-text-dim">Start a new meeting or join an existing one</p>
        </div>
        <div className="flex items-center gap-3">
          <button className="btn-terminal-success flex items-center gap-2">
            <svg className="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 4v16m8-8H4" />
            </svg>
            New Meeting
          </button>
        </div>
      </header>

      {/* Main content area */}
      <div className="flex-1 p-6 overflow-auto">
        <div className="max-w-4xl mx-auto">
          {/* Welcome card */}
          <div className="card-terminal mb-6">
            <div className="flex items-start gap-4">
              <div className="w-12 h-12 rounded-terminal bg-text-primary/10 flex items-center justify-center">
                <svg className="w-6 h-6 text-text-primary" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M19 11a7 7 0 01-7 7m0 0a7 7 0 01-7-7m7 7v4m0 0H8m4 0h4m-4-8a3 3 0 01-3-3V5a3 3 0 116 0v6a3 3 0 01-3 3z" />
                </svg>
              </div>
              <div className="flex-1">
                <h2 className="text-text-primary font-semibold mb-1">Welcome to macapy</h2>
                <p className="text-text-muted text-sm mb-4">
                  Your AI-powered meeting assistant. Capture audio, get real-time transcriptions,
                  and receive context-aware response suggestions.
                </p>
                <div className="flex gap-2">
                  <span className="badge-info">Real-time transcription</span>
                  <span className="badge-info">AI suggestions</span>
                  <span className="badge-info">Document context</span>
                </div>
              </div>
            </div>
          </div>

          {/* Quick start section */}
          <div className="grid grid-cols-2 gap-4 mb-6">
            <div className="card-terminal hover:border-text-primary/50 transition-colors cursor-pointer group">
              <div className="flex items-center gap-3 mb-3">
                <div className="w-8 h-8 rounded-terminal bg-accent-success/10 flex items-center justify-center">
                  <svg className="w-4 h-4 text-accent-success" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z" />
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z" />
                  </svg>
                </div>
                <h3 className="text-text-primary font-medium group-hover:text-text-secondary transition-colors">
                  Start Recording
                </h3>
              </div>
              <p className="text-text-muted text-sm">
                Begin capturing audio from your system or microphone.
              </p>
            </div>

            <div className="card-terminal hover:border-text-primary/50 transition-colors cursor-pointer group">
              <div className="flex items-center gap-3 mb-3">
                <div className="w-8 h-8 rounded-terminal bg-accent-cyan/10 flex items-center justify-center">
                  <svg className="w-4 h-4 text-accent-cyan" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12" />
                  </svg>
                </div>
                <h3 className="text-text-primary font-medium group-hover:text-text-secondary transition-colors">
                  Upload Context
                </h3>
              </div>
              <p className="text-text-muted text-sm">
                Add documents to provide context for AI suggestions.
              </p>
            </div>
          </div>

          {/* Terminal-style status display */}
          <div className="card-terminal bg-bg-primary">
            <div className="flex items-center gap-2 mb-3 pb-3 border-b border-border-default">
              <div className="w-3 h-3 rounded-full bg-accent-error"></div>
              <div className="w-3 h-3 rounded-full bg-accent-warning"></div>
              <div className="w-3 h-3 rounded-full bg-accent-success"></div>
              <span className="ml-2 text-text-dim text-xs">terminal</span>
            </div>
            <div className="font-mono text-sm space-y-1">
              <p className="text-text-dim">
                <span className="text-accent-success">$</span> macapy --version
              </p>
              <p className="text-text-muted">macapy v0.1.0</p>
              <p className="text-text-dim">
                <span className="text-accent-success">$</span> macapy status
              </p>
              <p className="text-text-muted">
                Backend: <span className="text-accent-warning">disconnected</span>
              </p>
              <p className="text-text-muted">
                Audio devices: <span className="text-text-primary">checking...</span>
              </p>
              <p className="text-text-dim flex items-center">
                <span className="text-accent-success">$</span>
                <span className="ml-1 cursor-blink"></span>
              </p>
            </div>
          </div>
        </div>
      </div>
    </main>
  );
}
