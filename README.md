# macapy.io - AI-Powered Personal Meeting Assistant

An intelligent meeting assistant that provides real-time transcription, contextual summaries, and smart response suggestions during online meetings.

## Overview

macapy.io captures audio from any meeting platform (Zoom, Google Meet, Microsoft Teams, Discord), transcribes conversations in real-time, generates rolling summaries, and suggests contextually-aware responses based on your uploaded documents (resume, project details, etc.).

**Perfect for**: Job interviews, client meetings, technical discussions, and any scenario where you need AI-powered assistance.

## Key Features

- 🎤 **Real-time Transcription**: 3-5 second latency using OpenAI Whisper
- 📝 **Rolling Summaries**: Automatic summarization every 60 seconds
- 💡 **Smart Suggestions**: Context-aware response suggestions in 5-8 seconds
- 📄 **Document Context**: Upload resumes, project docs, or notes for personalized assistance
- 🔍 **Semantic Search**: Vector-based search through your documents
- 🌐 **Platform-Agnostic**: Works with all major meeting platforms
- 🔒 **Privacy-First**: Runs locally on your machine
- 💾 **Meeting History**: Review past meetings, transcripts, and summaries

## Technology Stack

### Backend
- **Framework**: FastAPI (Python 3.11+)
- **Database**: PostgreSQL 15+ with pgvector extension
- **AI/ML**: OpenAI Whisper API, GPT-4-turbo, Embeddings API
- **Audio**: pyaudiowpatch (Windows), sounddevice (cross-platform)

### Frontend
- **Framework**: React 18 with TypeScript 5+
- **Build Tool**: Vite
- **State Management**: Zustand
- **Styling**: TailwindCSS + shadcn/ui

## Prerequisites

- **Python**: 3.11 or higher
- **Node.js**: 18 or higher
- **PostgreSQL**: 15 or higher
- **Virtual Audio Device**: VB-CABLE (Windows), BlackHole (macOS)
- **OpenAI API Key**: With access to Whisper and GPT-4

## Quick Start

### 1. Clone Repository

```bash
git clone <repository-url>
cd agentic_assistant
```

### 2. Set Up Environment Variables

```bash
cp .env.example .env
# Edit .env with your configuration
# IMPORTANT: Add your OpenAI API key
```

### 3. Database Setup

```bash
# Create database
createdb macapy_db

# Install pgvector extension
psql macapy_db -c "CREATE EXTENSION vector;"
```

### 4. Backend Setup

```bash
cd backend

# Create virtual environment
python -m venv .venv

# Activate virtual environment
# Windows:
.venv\Scripts\activate
# macOS/Linux:
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Run database migrations
alembic upgrade head

# Start backend server
uvicorn app.main:app --reload --port 8000
```

### 5. Frontend Setup

```bash
cd frontend

# Install dependencies
npm install

# Start development server
npm run dev
```

### 6. Access Application

- **Frontend**: http://localhost:3000
- **API Documentation**: http://localhost:8000/docs
- **API Alternative Docs**: http://localhost:8000/redoc

## Docker Deployment (Alternative)

```bash
# Copy environment variables
cp .env.example .env
# Edit .env with your OpenAI API key

# Start all services
docker-compose up -d

# View logs
docker-compose logs -f

# Stop services
docker-compose down
```

## Audio Setup

### Windows
1. Install **VB-CABLE Virtual Audio Device**
2. Set your meeting platform audio output to VB-CABLE
3. macapy.io will capture audio from VB-CABLE input

### macOS
1. Install **BlackHole** virtual audio device
2. Use Audio MIDI Setup to create Multi-Output Device
3. Route meeting audio through BlackHole

### Linux
1. Use PulseAudio or PipeWire loopback
2. Route meeting audio to loopback device

## Project Structure

```
agentic_assistant/
├── backend/              # FastAPI backend
│   ├── app/
│   │   ├── api/         # REST API endpoints
│   │   ├── models/      # SQLAlchemy models
│   │   ├── services/    # Business logic
│   │   └── main.py      # Application entry point
│   ├── tests/           # Backend tests
│   └── requirements.txt
├── frontend/            # React frontend
│   ├── src/
│   │   ├── components/  # React components
│   │   ├── hooks/       # Custom hooks
│   │   └── store/       # State management
│   └── package.json
├── reference/           # Documentation
│   ├── ARCHITECTURE.md  # System architecture
│   ├── ROADMAP.md      # Development roadmap
│   └── DATABASE_SCHEMA.md
├── CLAUDE.md           # Claude Code guidance
└── TECHNOLOGY_STACK.md # Tech stack details
```

## Usage

### 1. Start a New Meeting

1. Open macapy.io dashboard
2. Click "New Meeting"
3. Enter meeting title and select platform
4. (Optional) Upload context documents (resume, notes, etc.)
5. Click "Start Audio Capture"

### 2. During the Meeting

- View real-time transcription in the main panel
- See rolling summaries appear every 60 seconds
- Get smart response suggestions when questions are detected
- Click suggestions to copy them or mark as used

### 3. After the Meeting

- Review complete transcript
- Export summaries and transcripts
- View meeting in history for future reference

## Development

### Running Tests

**Backend:**
```bash
cd backend
pytest tests/ -v
```

**Frontend:**
```bash
cd frontend
npm test
```

### Database Migrations

**Create new migration:**
```bash
cd backend
alembic revision --autogenerate -m "Description"
```

**Apply migrations:**
```bash
alembic upgrade head
```

**Rollback:**
```bash
alembic downgrade -1
```

### Code Quality

**Backend:**
```bash
# Format code
black backend/

# Lint
pylint backend/app/
```

**Frontend:**
```bash
# Format code
npm run format

# Lint
npm run lint
```

## Performance

- **Transcription**: 3-5 seconds latency
- **Suggestions**: 5-8 seconds from question detection
- **Summaries**: Generated every 60 seconds
- **WebSocket**: <100ms message delivery

## API Documentation

Interactive API documentation is automatically generated and available at:
- **Swagger UI**: http://localhost:8000/docs
- **ReDoc**: http://localhost:8000/redoc

## Troubleshooting

### Audio Not Capturing
- Verify virtual audio device is installed and configured
- Check that meeting audio is routed to virtual device
- Test audio capture: `python -c "import sounddevice; print(sounddevice.query_devices())"`

### Database Connection Errors
- Ensure PostgreSQL is running: `pg_isready`
- Verify DATABASE_URL in `.env`
- Check pgvector extension: `psql macapy_db -c "SELECT * FROM pg_extension WHERE extname='vector';"`

### OpenAI API Errors
- Verify API key is correct in `.env`
- Check API quota and rate limits
- Monitor costs at https://platform.openai.com/usage

### High Latency
- Check internet connection (API calls require internet)
- Monitor OpenAI API status
- Consider using local Whisper model (see ROADMAP.md Stage 7)

## Contributing

This is a personal project. Contributions, issues, and feature requests are welcome!

## Documentation

- **CLAUDE.md**: Guidance for Claude Code when working with this codebase
- **TECHNOLOGY_STACK.md**: Comprehensive guide to all technologies used
- **reference/ARCHITECTURE.md**: Detailed system architecture
- **reference/ROADMAP.md**: Development roadmap with 7 stages
- **reference/DATABASE_SCHEMA.md**: Complete database schema

## Development Roadmap

The project follows a 7-stage development plan:

1. ✅ **Foundation & Environment** (Current Stage)
2. **Audio Pipeline** - Real-time transcription
3. **Document Processing** - Context extraction and search
4. **AI Integration** - Summaries and suggestions
5. **UI Development** - Complete dashboard
6. **Integration & Testing** - End-to-end workflows
7. **Advanced Features** - Speaker diarization, local models

See `reference/ROADMAP.md` for detailed task breakdown.

## License

[Specify License Here]

## Support

For issues, questions, or suggestions:
- Check the documentation in `reference/`
- Review troubleshooting section above
- Open an issue on GitHub

## Acknowledgments

- OpenAI for Whisper and GPT-4 APIs
- PostgreSQL and pgvector for vector search capabilities
- FastAPI and React communities

---

**Built with ❤️ for better meeting experiences**
