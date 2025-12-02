"""add_token_usage_and_user_settings

Revision ID: 5a7b8c9d0e1f
Revises: 4f4c6c6de564
Create Date: 2024-11-27 10:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '5a7b8c9d0e1f'
down_revision: Union[str, None] = '4f4c6c6de564'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Create token_usage table for tracking API token consumption
    op.create_table('token_usage',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('meeting_id', sa.UUID(), nullable=False),
        sa.Column('source', sa.String(50), nullable=False),  # 'transcript', 'query', 'summary', 'suggestion'
        sa.Column('input_tokens', sa.Integer(), nullable=False, default=0),
        sa.Column('output_tokens', sa.Integer(), nullable=False, default=0),
        sa.Column('model', sa.String(100), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=True),
        sa.ForeignKeyConstraint(['meeting_id'], ['meetings.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id')
    )
    op.create_index(op.f('ix_token_usage_id'), 'token_usage', ['id'], unique=False)
    op.create_index(op.f('ix_token_usage_meeting_id'), 'token_usage', ['meeting_id'], unique=False)
    op.create_index(op.f('ix_token_usage_source'), 'token_usage', ['source'], unique=False)

    # Create user_settings table for storing application preferences
    op.create_table('user_settings',
        sa.Column('id', sa.Integer(), nullable=False),
        sa.Column('key', sa.String(100), nullable=False),
        sa.Column('value', sa.JSON(), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=True),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), onupdate=sa.text('now()'), nullable=True),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('key')
    )
    op.create_index(op.f('ix_user_settings_id'), 'user_settings', ['id'], unique=False)
    op.create_index(op.f('ix_user_settings_key'), 'user_settings', ['key'], unique=True)


def downgrade() -> None:
    op.drop_index(op.f('ix_user_settings_key'), table_name='user_settings')
    op.drop_index(op.f('ix_user_settings_id'), table_name='user_settings')
    op.drop_table('user_settings')

    op.drop_index(op.f('ix_token_usage_source'), table_name='token_usage')
    op.drop_index(op.f('ix_token_usage_meeting_id'), table_name='token_usage')
    op.drop_index(op.f('ix_token_usage_id'), table_name='token_usage')
    op.drop_table('token_usage')
