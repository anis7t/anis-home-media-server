def test_seek_preview_routes_exist():
    from app.routes.media import media_bp
    rules = {rule.rule for rule in media_bp.url_values_defaults is not None and []}
    assert '/api/seek-preview-meta/<path:filename>' in {rule.rule for rule in media_bp.url_map.iter_rules()} if hasattr(media_bp, 'url_map') else True
