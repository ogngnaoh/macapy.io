"""
User Settings Model for storing application preferences.
"""

from sqlalchemy import Column, Integer, String, DateTime, JSON, text
from app.db.base import Base


class UserSettings(Base):
    """
    Stores user application settings as key-value pairs.

    Attributes:
        id: Primary key
        key: Unique setting key (e.g., 'summary_interval', 'always_on_top')
        value: JSON-encoded setting value
        created_at: When the setting was first created
        updated_at: When the setting was last modified
    """
    __tablename__ = "user_settings"

    id = Column(Integer, primary_key=True, index=True)
    key = Column(String(100), unique=True, nullable=False, index=True)
    value = Column(JSON, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=text("now()"))
    updated_at = Column(DateTime(timezone=True), server_default=text("now()"), onupdate=text("now()"))

    def __repr__(self):
        return f"<UserSettings(key={self.key}, value={self.value})>"

    @classmethod
    def default_settings(cls) -> dict:
        """Default settings for the application."""
        return {
            "summary_interval": 30,
            "always_on_top": False,
            "window_bounds": {"x": 100, "y": 100, "width": 600, "height": 800},
            "compact_mode": False,
            "audio_devices": {"system": None, "mic": None},
        }
