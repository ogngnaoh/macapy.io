from typing import List
import openai
from app.config import settings

class EmbeddingService:
    def __init__(self):
        self.client = openai.AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
        self.model = "text-embedding-3-small"

    async def generate_embedding(self, text: str) -> List[float]:
        """Generates an embedding vector for the given text."""
        text = text.replace("\n", " ")
        response = await self.client.embeddings.create(
            input=[text],
            model=self.model
        )
        return response.data[0].embedding

    async def generate_embeddings(self, texts: List[str]) -> List[List[float]]:
        """Generates embeddings for a list of texts."""
        # OpenAI has a limit on batch size, might need to chunk if list is too large
        # For now assuming reasonable batch size
        cleaned_texts = [t.replace("\n", " ") for t in texts]
        response = await self.client.embeddings.create(
            input=cleaned_texts,
            model=self.model
        )
        return [data.embedding for data in response.data]
