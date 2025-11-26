import openai
from typing import List, Optional
import json
import logging
from app.config import settings

logger = logging.getLogger(__name__)

class LLMService:
    def __init__(self):
        self.client = openai.AsyncOpenAI(api_key=settings.OPENAI_API_KEY)
        self.model = "gpt-4-turbo-preview" # Or gpt-4o if available/preferred

    async def generate_summary(self, transcript_text: str) -> str:
        """
        Generates a concise summary of the provided transcript segment.
        """
        if not transcript_text.strip():
            return ""

        prompt = f"""
        You are a meeting assistant. Summarize the following conversation segment.
        Focus on: key decisions, action items, and important questions raised.
        Keep it concise (under 3 bullet points).

        Transcript:
        {transcript_text}
        """

        try:
            response = await self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": "You are a helpful meeting assistant."},
                    {"role": "user", "content": prompt}
                ],
                temperature=0.5,
                max_tokens=200
            )
            return response.choices[0].message.content.strip()
        except Exception as e:
            logger.error(f"Error generating summary: {e}", exc_info=True)
            return ""

    async def detect_question(self, text_segment: str) -> bool:
        """
        Determines if the text segment contains a question directed at the user that requires a response.
        """
        # Simple heuristic first
        if "?" not in text_segment:
            return False
            
        prompt = f"""
        Analyze the following text segment from a meeting. 
        Does it contain a question directed at the participant that requires a response?
        Reply with only "YES" or "NO".

        Text:
        {text_segment}
        """
        
        try:
            response = await self.client.chat.completions.create(
                model="gpt-3.5-turbo", # Cheaper model for detection
                messages=[{"role": "user", "content": prompt}],
                temperature=0,
                max_tokens=5
            )
            return "YES" in response.choices[0].message.content.upper()
        except Exception as e:
            logger.error(f"Error detecting question: {e}", exc_info=True)
            return False

    async def generate_suggestion(self, question: str, transcript_context: str, document_context: List[str]) -> List[str]:
        """
        Generates response suggestions based on the question, recent transcript, and retrieved documents.
        """
        context_str = "\n\n".join(document_context)
        
        prompt = f"""
        You are helping a user in a meeting/interview.
        
        User's Background / Context (from documents):
        {context_str}

        Recent Conversation:
        {transcript_context}

        Question Detected:
        {question}

        Provide 3 distinct, conversational response options for the user. 
        Keep them brief and natural.
        Format as a JSON list of strings.
        """

        try:
            response = await self.client.chat.completions.create(
                model=self.model,
                messages=[
                    {"role": "system", "content": "You are a helpful assistant providing real-time interview/meeting aid."},
                    {"role": "user", "content": prompt}
                ],
                temperature=0.7,
                response_format={"type": "json_object"}
            )
            content = response.choices[0].message.content
            data = json.loads(content)
            # Handle different potential JSON structures if the model deviates, but json_object mode helps
            if "suggestions" in data:
                return data["suggestions"]
            elif "options" in data:
                return data["options"]
            # Fallback if it returns just a list in a key we didn't guess, or just the list
            # But usually with json_object it enforces valid JSON. 
            # Let's assume it returns { "suggestions": [...] } if we prompted well, 
            # but to be safe we can ask for a specific key in prompt or parse loosely.
            # Let's refine prompt to specify key.
            return list(data.values())[0] if data else []
            
        except Exception as e:
            logger.error(f"Error generating suggestions: {e}", exc_info=True)
            return []
