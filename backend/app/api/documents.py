from fastapi import APIRouter, Depends, UploadFile, File, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from uuid import UUID
from typing import List

from app.db.session import get_db
from app.services.context_service import ContextService
from app.schemas.document import DocumentResponse

router = APIRouter()

@router.post("/meetings/{meeting_id}/documents", response_model=DocumentResponse)
async def upload_document(
    meeting_id: UUID,
    file: UploadFile = File(...),
    db: AsyncSession = Depends(get_db)
):
    service = ContextService(db)
    try:
        doc = await service.process_document(meeting_id, file)
        return doc
    except Exception as e:
        # Log the error properly in production
        print(f"Error processing document: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/meetings/{meeting_id}/documents", response_model=List[DocumentResponse])
async def list_documents(
    meeting_id: UUID,
    db: AsyncSession = Depends(get_db)
):
    service = ContextService(db)
    return await service.get_documents(meeting_id)

@router.delete("/{document_id}")
async def delete_document(
    document_id: int,
    db: AsyncSession = Depends(get_db)
):
    service = ContextService(db)
    await service.delete_document(document_id)
    return {"status": "success"}
