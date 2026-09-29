"""Casting API: find LAN playback devices (DLNA renderers, Chromecasts) and drive them.

The browser and the phone app are thin clients here: they list devices, ask for a
filename to be cast, then poll status. Nothing that reaches a TV comes from the
client except a device id (resolved against the discovery cache), a filename
(validated by ``safe_path``) and numeric values.
"""
import logging

from flask import Blueprint, jsonify, request

from app.services.cast_service import registry, resolve_origin

log = logging.getLogger(__name__)

cast_bp = Blueprint('cast', __name__)

ACTIONS = {'play', 'pause', 'stop', 'seek', 'volume'}


def _payload() -> dict:
    return request.get_json(silent=True) or {}


def _float_or_none(value):
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError):
        return None


@cast_bp.route('/api/cast/devices')
def cast_devices():
    """Discovered devices. ``?refresh=1`` starts a new scan; otherwise a cached list
    is returned and ``scanning`` tells the client to poll again."""
    force = str(request.args.get('refresh', '')).lower() in ('1', 'true', 'yes')
    return jsonify(registry().devices(force=force))


@cast_bp.route('/api/cast/play', methods=['POST'])
def cast_play():
    payload = _payload()
    device_id = str(payload.get('device_id') or '').strip()
    filename = str(payload.get('filename') or '').strip()
    if not device_id or not filename:
        return jsonify({'ok': False, 'error': 'device_id and filename are required'}), 400
    result = registry().play(
        device_id,
        filename,
        position=_float_or_none(payload.get('position')),
        origin=resolve_origin(payload.get('origin'), request.host_url),
    )
    return jsonify(result), (200 if result.get('ok') else 400)


@cast_bp.route('/api/cast/control', methods=['POST'])
def cast_control():
    payload = _payload()
    device_id = str(payload.get('device_id') or '').strip()
    action = str(payload.get('action') or '').strip().lower()
    if not device_id:
        return jsonify({'ok': False, 'error': 'device_id is required'}), 400
    if action not in ACTIONS:
        return jsonify({'ok': False, 'error': f'action must be one of {sorted(ACTIONS)}'}), 400
    value = _float_or_none(payload.get('value'))
    if action in ('seek', 'volume'):
        if value is None:
            return jsonify({'ok': False, 'error': f'{action} needs a numeric value'}), 400
        if action == 'volume' and not 0 <= value <= 100:
            return jsonify({'ok': False, 'error': 'volume must be between 0 and 100'}), 400
    result = registry().control(device_id, action, value)
    return jsonify(result), (200 if result.get('ok') else 400)


@cast_bp.route('/api/cast/status')
def cast_status():
    device_id = str(request.args.get('device_id') or '').strip()
    if not device_id:
        return jsonify({'ok': False, 'error': 'device_id is required'}), 400
    result = registry().status(device_id)
    return jsonify(result), (200 if result.get('ok') else 400)
