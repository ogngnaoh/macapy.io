import fitz  # PyMuPDF
import docx
import os
from typing import List, Dict, Any

class DocumentService:
    def __init__(self):
        pass

    def parse_file(self, file_path: str, file_type: str) -> str:
        """Parses a file and returns its text content."""
        if not os.path.exists(file_path):
            raise FileNotFoundError(f"File not found: {file_path}")

        if file_type.lower() == "pdf":
            return self._parse_pdf(file_path)
        elif file_type.lower() in ["docx", "doc"]:
            return self._parse_docx(file_path)
        elif file_type.lower() in ["txt", "md"]:
            return self._parse_text(file_path)
        else:
            raise ValueError(f"Unsupported file type: {file_type}")

    def _parse_pdf(self, file_path: str) -> str:
        text = ""
        with fitz.open(file_path) as doc:
            for page in doc:
                text += page.get_text()
        return text

    def _parse_docx(self, file_path: str) -> str:
        doc = docx.Document(file_path)
        return "\n".join([para.text for para in doc.paragraphs])

    def _parse_text(self, file_path: str) -> str:
        with open(file_path, "r", encoding="utf-8") as f:
            return f.read()

    def chunk_text(self, text: str, chunk_size: int = 1000, overlap: int = 200) -> List[Dict[str, Any]]:
        """Chunks text into smaller segments with overlap."""
        chunks = []
        start = 0
        text_len = len(text)

        while start < text_len:
            end = start + chunk_size
            chunk_text = text[start:end]
            
            # Try to find a sentence break if we are not at the end
            if end < text_len:
                last_period = chunk_text.rfind('.')
                if last_period != -1 and last_period > chunk_size * 0.5:
                    end = start + last_period + 1
                    chunk_text = text[start:end]

            chunks.append({
                "text": chunk_text,
                "index": len(chunks),
                "start_char": start,
                "end_char": end
            })
            
            start = end - overlap
            if start < 0: # Should not happen but safety check
                start = 0
                
            # Avoid infinite loop if overlap >= chunk_size or no progress
            if start >= end:
                start = end 

        return chunks
