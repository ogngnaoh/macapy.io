"""
Application configuration using Pydantic Settings.
Loads environment variables from .env file.
"""

from pathlib import Path
from pydantic_settings import BaseSettings, SettingsConfigDict
from typing import Optional

# Get the project root directory (parent of backend/)
BASE_DIR = Path(__file__).resolve().parent.parent.parent
ENV_FILE = BASE_DIR / ".env"


class Settings(BaseSettings):
    """
    Application settings loaded from environment variables.

    Uses Pydantic Settings to automatically load and validate
    environment variables from .env file.
    """

    # Database Configuration
    DATABASE_URL: str

    # OpenAI API Configuration
    OPENAI_API_KEY: str

    # Application Configuration
    SECRET_KEY: str
    DEBUG: bool = True

    # Server Configuration
    BACKEND_HOST: str = "0.0.0.0"
    BACKEND_PORT: int = 8000
    FRONTEND_PORT: int = 3000

    # CORS Configuration
    ALLOWED_ORIGINS: str = "http://localhost:3000,http://127.0.0.1:3000,http://localhost:5173,http://127.0.0.1:5173"

    # Audio Configuration
    AUDIO_SAMPLE_RATE: int = 16000
    AUDIO_CHANNELS: int = 1
    AUDIO_CHUNK_DURATION: float = 1.0

    # AI Model Configuration
    WHISPER_MODEL: str = "whisper-1"
    GPT_MODEL: str = "gpt-5-nano-2025-08-07"
    EMBEDDING_MODEL: str = "text-embedding-3-small"
    EMBEDDING_DIMENSION: int = 1536

    # Realtime API Configuration
    USE_REALTIME_API: bool = True  # Feature flag: True = Realtime API, False = batch Whisper
    REALTIME_MODEL: str = "gpt-4o-realtime-preview-2024-12-17"
    REALTIME_SAMPLE_RATE: int = 24000  # 24kHz required by Realtime API

    # Vector Search Configuration
    VECTOR_SIMILARITY_METRIC: str = "cosine"
    VECTOR_TOP_K: int = 5

    # File Upload Configuration
    MAX_UPLOAD_SIZE: int = 10485760  # 10MB in bytes
    UPLOAD_DIR: str = "backend/uploads"

    # Meeting Configuration
    SUMMARY_INTERVAL: int = 30  # seconds (user preference: 30s for more frequent updates)
    TRANSCRIPTION_LATENCY_TARGET: int = 5  # seconds
    SUGGESTION_LATENCY_TARGET: int = 8  # seconds

    # Logging Configuration
    LOG_LEVEL: str = "INFO"
    LOG_FILE: str = "logs/macapy.log"

    model_config = SettingsConfigDict(
        env_file=str(ENV_FILE),
        env_file_encoding="utf-8",
        case_sensitive=True,
        extra="ignore"
    )

    @property
    def allowed_origins_list(self) -> list[str]:
        """Parse ALLOWED_ORIGINS comma-separated string into a list."""
        return [origin.strip() for origin in self.ALLOWED_ORIGINS.split(",")]


# Create a global settings instance
settings = Settings()
