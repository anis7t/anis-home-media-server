from app import create_app


def test_seek_preview_endpoints_registered():
    app = create_app({'TESTING': True})
    routes = {rule.rule for rule in app.url_map.iter_rules()}
    assert '/api/seek-preview-meta/<path:filename>' in routes
    assert '/seek-preview/<path:filename>/<thumb>' in routes
