# macapy.io 🎙️

**The RAG-Powered Agentic Meeting Assistant**

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Status](https://img.shields.io/badge/status-v1.0-success.svg)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS-lightgrey.svg)

**macapy.io** is an Electron-based desktop application designed to transform how you experience online meetings. By leveraging **OpenAI Whisper** for real-time transcription and **GPT-5 nano** for intelligent reasoning, it acts as your personal cognitive augmentation layer—providing live summaries, detecting questions, and suggesting context-aware responses in real-time.

---

## 🚀 Features

- **🎙️ Real-Time Transcription**: Captures system audio with < 5s latency using native APIs (WASAPI on Windows, ScreenCaptureKit on macOS).
- **📝 Rolling Summaries**: Automatically generates concise summaries every 30 seconds to help you stay on track.
- **🧠 Intelligent Question Detection**: Detects when you are asked a question and instantly suggests 2-3 relevant responses.
- **💬 Contextual AI Assistant**: Ask questions about the current meeting or past discussions using the built-in query interface.
- **📂 Document Context**: Upload PDFs or docs to give the AI specific knowledge for your meeting (e.g., resumes, specs).
- **🔒 Privacy First**: All data is stored locally or securely processed via your own API keys. Pause/Resume capture at any time.
- **🎨 Modern UI**: A sleek, dark-mode-only interface built with Electron and React, designed to be unobtrusive.

## 📸 Screenshots & Demos

> **Note**: Replace the placeholder paths below with your actual image files.

<div align="center">
  <!-- Main Demo GIF or Screenshot -->
  <img src="docs/media/main-demo.gif" alt="macapy.io Demo" width="100%" />
  <p><em>Real-time transcription and AI summaries in action</em></p>
</div>

### Core Interface

| Live Transcription | AI Suggestions |
|:---:|:---:|
| <img src="docs/media/transcript.png" alt="Transcript View" width="400"/> | <img src="docs/media/suggestions.png" alt="Suggestions View" width="400"/> |
| *Dual-channel transcription with auto-scroll* | *Context-aware response suggestions* |

## 🛠️ Tech Stack

### Frontend
- **Framework**: React 18 + TypeScript
- **Shell**: Electron 28+
- **Styling**: TailwindCSS + Shadcn/UI
- **State Management**: Zustand
- **Build Tool**: Vite

### Backend
- **API**: FastAPI (Python 3.10+)
- **Database**: PostgreSQL + pgvector (for semantic search)
- **AI Services**: OpenAI Whisper (Transcription), GPT-5 nano (Reasoning)
- **Real-time**: WebSockets for live updates

## 📋 Prerequisites

Before you begin, ensure you have the following installed:
- **Node.js** (v18 or higher)
- **Python** (v3.10 or higher)
- **PostgreSQL** (v14 or higher)
- **OpenAI API Key** (with access to Whisper and GPT-4/5 models)

## ⚡ Installation

1.  **Clone the repository**
    ```bash
    git clone https://github.com/yourusername/macapy.io.git
    cd macapy.io
    ```

2.  **Backend Setup**
    ```bash
    # Create virtual environment
    python -m venv .venv
    
    # Activate (Windows)
    .venv\Scripts\activate
    # Activate (macOS/Linux)
    # source .venv/bin/activate

    # Install dependencies
    pip install -r backend/requirements.txt
    ```

3.  **Database Setup**
    ```bash
    # Create database
    createdb macapy_db
    
    # Enable pgvector extension
    psql macapy_db -c "CREATE EXTENSION vector;"
    
    # Run migrations
    cd backend
    alembic upgrade head
    cd ..
    ```

4.  **Environment Configuration**
    Copy `.env.example` to `.env` and fill in your details:
    ```bash
    cp .env.example .env
    ```
    *Ensure `OPENAI_API_KEY` and `DATABASE_URL` are set correctly.*

5.  **Frontend Setup**
    ```bash
    cd frontend
    npm install
    ```

## 🏃‍♂️ Usage

### 1. Start the Backend
Open a terminal in the project root:
```bash
# Ensure .venv is activated
uvicorn backend.app.main:app --reload --port 8000
```

### 2. Start the Application
Open a new terminal:
```bash
cd frontend
npm run dev
```
The application window should appear. You can now:
- Click **Start Meeting** to begin capturing audio.
- Watch the **Live Transcript** appear in real-time.
- See **Summaries** generate automatically.
- Use the **Query Input** to ask the AI questions.

## 📖 Documentation

For detailed technical documentation, please refer to the `docs/` directory:
- [**Product Requirements (PRD)**](docs/PRD.md): Detailed feature specifications.
- [**Architecture**](docs/ARCHITECTURE.md): System design and data flow.
- [**Frontend Guidelines**](frontend-guideline.md): UI/UX design principles.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
