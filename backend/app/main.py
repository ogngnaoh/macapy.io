"""
macapy.io - AI-Powered Personal Meeting Assistant
Main FastAPI application entry point
"""

import logging
import sys

# Configure logging to show application logs
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(name)s: %(message)s',
    handlers=[logging.StreamHandler(sys.stdout)]
)
# Also set specific loggers for our app
logging.getLogger('app').setLevel(logging.DEBUG)

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from app.config import settings
import app.models # Register all models

# Create FastAPI application instance
app = FastAPI(
    title="macapy.io API",
    description="AI-Powered Personal Meeting Assistant - Backend API",
    version="0.1.0",
    docs_url="/docs",
    redoc_url="/redoc",
    debug=settings.DEBUG,
)

# Configure CORS using settings
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/")
async def root():
    """Root endpoint - Health check"""
    return {
        "status": "online",
        "service": "macapy.io API",
        "version": "0.1.0",
        "docs": "/docs",
    }


@app.get("/health")
async def health_check():
    """Health check endpoint"""
    return {"status": "healthy"}


from app.api.api import api_router

# Include centralized API router
app.include_router(api_router, prefix="/api")




if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
    )
