/**
 * macapy.io - AI-Powered Personal Meeting Assistant
 * Main React Application Component
 */

import { useState } from 'react';

function App() {
  const [status, setStatus] = useState<string>('Initializing...');

  // TODO: Add router, state management, and main layout
  // TODO: Connect to backend WebSocket
  // TODO: Implement meeting dashboard

  return (
    <div className="min-h-screen bg-gray-100">
      <header className="bg-white shadow">
        <div className="max-w-7xl mx-auto py-6 px-4 sm:px-6 lg:px-8">
          <h1 className="text-3xl font-bold text-gray-900">macapy.io</h1>
          <p className="mt-1 text-sm text-gray-600">
            AI-Powered Personal Meeting Assistant
          </p>
        </div>
      </header>

      <main>
        <div className="max-w-7xl mx-auto py-6 sm:px-6 lg:px-8">
          <div className="px-4 py-6 sm:px-0">
            <div className="border-4 border-dashed border-gray-200 rounded-lg h-96 p-8">
              <div className="text-center">
                <h2 className="text-2xl font-semibold text-gray-700 mb-4">
                  Welcome to macapy.io
                </h2>
                <p className="text-gray-600 mb-4">
                  Status: {status}
                </p>
                <p className="text-sm text-gray-500">
                  The application is under development. See README.md for setup
                  instructions.
                </p>
              </div>
            </div>
          </div>
        </div>
      </main>
    </div>
  );
}

export default App;
