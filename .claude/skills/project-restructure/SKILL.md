---
name: project-restructure
description: Restructure Python projects to follow industry-standard practices for GitHub portfolios and professional codebases. Use when users want to (1) organize or reorganize their project structure, (2) prepare a project for GitHub showcase, (3) set up proper test/docs/scripts directories, (4) create or improve README.md, (5) add standard files like LICENSE, .gitignore, setup.py, or (6) review project organization against best practices.
---

# Project Restructure

Restructure Python projects to follow industry-standard practices.

## Workflow

1. **Analyze current structure** - Run `find . -type f -name "*.py" | head -50` and `ls -la` to understand existing layout
2. **Identify issues** - Compare against standard structure below
3. **Plan changes** - List files to move/create, get user approval before restructuring
4. **Execute restructuring** - Move files, create directories, update imports
5. **Add missing standard files** - README.md, .gitignore, LICENSE, requirements.txt
6. **Verify** - Ensure imports still work, tests pass

## Standard Directory Layout

```
project_name/
├── README.md
├── LICENSE
├── .gitignore
├── requirements.txt
├── setup.py
├── project_name/        # Main package (matches repo name, no hyphens)
│   ├── __init__.py
│   ├── main.py
│   ├── config.py
│   ├── models/
│   ├── services/
│   ├── routes/
│   └── utils/
├── tests/
│   ├── conftest.py
│   ├── unit/
│   └── integration/
├── scripts/             # Automation utilities (NOT tests)
├── docs/
└── .github/workflows/
```

## Key Rules

- **Package name**: Use underscores, not hyphens (`my_project` not `my-project`)
- **Tests location**: Always in `/tests`, never in project root or `/scripts`
- **Scripts vs Tests**: `/scripts` for manual utilities, `/tests` for pytest
- **No root clutter**: Only config files (README, requirements, etc.) in root

## File Placement

| File Type | Correct Location |
|-----------|------------------|
| Unit tests | `tests/unit/` |
| Integration tests | `tests/integration/` |
| Manual/debug scripts | `scripts/` |
| API endpoints | `project_name/routes/` or `project_name/api/` |
| Business logic | `project_name/services/` |
| Database models | `project_name/models/` |
| Helper functions | `project_name/utils/` |

## README Template

```markdown
# Project Name

Brief 1-2 sentence description.

## Features
- Feature 1
- Feature 2

## Tech Stack
- Python 3.9+
- Framework

## Installation
git clone https://github.com/username/project.git
cd project
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt

## Usage
from project_name import main
main.run()

## Running Tests
pytest

## License
MIT
```

## GitHub Portfolio Checklist

See [references/structure.md](references/structure.md) for detailed checklist and examples.
