# Project Structure Reference

## GitHub Portfolio Checklist

### Required Files
- [ ] `README.md` - Title, tech stack, installation, usage, tests
- [ ] `LICENSE` - MIT recommended for personal projects
- [ ] `.gitignore` - Exclude venv/, __pycache__, .env, .DS_Store
- [ ] `requirements.txt` - Pinned dependencies

### Quality Indicators
- [ ] Clear commit history (small, logical commits)
- [ ] No hard-coded secrets or API keys
- [ ] No TODOs in production code
- [ ] Docstrings for key functions
- [ ] Tests pass (use GitHub Actions to verify)

### Avoid
- Single massive commit for entire project
- Unclear commit messages ("fix stuff")
- Missing or vague README
- Debug code in production

## Module Organization

### models/
Database schemas, ORM entities, data classes.

```python
# models/user.py
class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True)
    email = Column(String, unique=True)
```

### services/
Business logic, API calls, computations.

```python
# services/user_service.py
async def create_user(db: AsyncSession, email: str) -> User:
    user = User(email=email)
    db.add(user)
    await db.commit()
    return user
```

### routes/ (or api/)
API endpoints, request handlers.

```python
# routes/users.py
@router.post("/users")
async def create_user(request: UserCreate, db: AsyncSession = Depends(get_db)):
    return await user_service.create_user(db, request.email)
```

### utils/
Reusable helpers (formatting, validation).

```python
# utils/validators.py
def validate_email(email: str) -> bool:
    return "@" in email and "." in email
```

### config.py
Environment variables, settings.

```python
# config.py
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    database_url: str
    secret_key: str

    class Config:
        env_file = ".env"
```

## Testing Structure

```
tests/
├── __init__.py
├── conftest.py          # Shared fixtures
├── unit/
│   ├── __init__.py
│   ├── test_models.py
│   └── test_services.py
└── integration/
    ├── __init__.py
    └── test_api.py
```

### conftest.py Example

```python
import pytest
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession

@pytest.fixture
async def db_session():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with AsyncSession(engine) as session:
        yield session
```

### Test File Requirements
- All pytest files must define tests inside functions
- Never run code at import time - use fixtures
- Use `@pytest.mark.skipif` for tests requiring external services

## Standard .gitignore

```
# Python
__pycache__/
*.py[cod]
*.egg-info/
dist/
build/
.eggs/

# Virtual environments
venv/
.venv/
ENV/

# IDE
.idea/
.vscode/
*.swp

# Environment
.env
.env.local

# OS
.DS_Store
Thumbs.db

# Testing
.coverage
htmlcov/
.pytest_cache/

# Logs
*.log
```

## Docstring Style (Google)

```python
def get_user(user_id: int) -> User:
    """Retrieve a user by ID.

    Args:
        user_id: The unique user identifier.

    Returns:
        User object containing name, email, etc.

    Raises:
        UserNotFoundError: If user doesn't exist.
    """
```
