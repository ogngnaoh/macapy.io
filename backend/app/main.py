"""
macapy.io - AI-Powered Personal Meeting Assistant
Main FastAPI application entry point
"""

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

# Create FastAPI application instance
app = FastAPI(
    title="macapy.io API",
    description="AI-Powered Personal Meeting Assistant - Backend API",
    version="0.1.0",
    docs_url="/docs",
    redoc_url="/redoc",
)

# Configure CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=[
        "http://localhost:3000",
        "http://127.0.0.1:3000",
    ],
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


# TODO: Add API routers
# from app.api import meetings, documents, transcripts
# app.include_router(meetings.router, prefix="/api/meetings", tags=["meetings"])
# app.include_router(documents.router, prefix="/api/documents", tags=["documents"])
# app.include_router(transcripts.router, prefix="/api/transcripts", tags=["transcripts"])

# TODO: Add WebSocket endpoint
# @app.websocket("/ws/meeting/{meeting_id}")
# async def websocket_endpoint(websocket: WebSocket, meeting_id: str):
#     await websocket.accept()
#     # WebSocket logic here


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "app.main:app",
        host="0.0.0.0",
        port=8000,
        reload=True,
    )
