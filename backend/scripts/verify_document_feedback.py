import asyncio
import sys
import os
from pathlib import Path
from datetime import datetime

# Add backend to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.db.session import get_db
from app.models.meeting import Meeting, MeetingStatus
from app.services.context_service import ContextService
from fastapi import UploadFile

async def verify_document_feedback():
    print("Starting Document Feedback Verification...")
    
    # Create a dummy file
    dummy_content = b"This is a test document content."
    dummy_filename = "test_doc.txt"
    with open(dummy_filename, "wb") as f:
        f.write(dummy_content)
        
    try:
        # 1. Create Meeting
        async for session in get_db():
            new_meeting = Meeting(
                title="Document Test Meeting",
                status=MeetingStatus.PENDING,
                start_time=datetime.utcnow()
            )
            session.add(new_meeting)
            await session.commit()
            await session.refresh(new_meeting)
            meeting_id = str(new_meeting.id)
            print(f"Created meeting: {meeting_id}")
            
            try:
                context_service = ContextService(session)
                
                # Mock embedding service
                async def mock_generate_embeddings(texts):
                    return [[0.1] * 1536 for _ in texts]
                context_service.embedding_service.generate_embeddings = mock_generate_embeddings

                # 2. Upload Document (Simulate Service Call)
                with open(dummy_filename, "rb") as f:
                    upload_file = UploadFile(filename=dummy_filename, file=f)
                    
                    print("Uploading document...")
                    doc = await context_service.process_document(new_meeting.id, upload_file)
                    
                    if doc.filename == dummy_filename:
                        print("✅ Document uploaded successfully")
                        doc_id = doc.id
                    else:
                        print("❌ Document upload failed")
                        return

                # 3. Verify Document in DB (Implicit)
                
                # 4. Delete Document
                print("Deleting document...")
                await context_service.delete_document(doc_id)
                print("✅ Document deleted successfully")
                
                print("✅ Document Feedback Verification PASSED")
                with open("result.txt", "w") as f:
                    f.write("PASSED")
                
            except Exception as e:
                import traceback
                with open("error_doc.txt", "w", encoding="utf-8") as f:
                    traceback.print_exc(file=f)
                print(f"❌ Verification failed: {e}")
            finally:
                # Cleanup Meeting
                await session.delete(new_meeting)
                await session.commit()
                
    finally:
        # Cleanup file
        if os.path.exists(dummy_filename):
            os.remove(dummy_filename)

if __name__ == "__main__":
    asyncio.run(verify_document_feedback())
