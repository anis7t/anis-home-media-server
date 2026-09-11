"""Route blueprints package."""
from app.routes.pages import pages_bp
from app.routes.media import media_bp
from app.routes.subtitles import subtitles_bp
from app.routes.api import api_bp
from app.routes import upload as _upload_routes  # noqa: F401 - registers chunked upload routes

__all__ = ['pages_bp', 'media_bp', 'subtitles_bp', 'api_bp']
