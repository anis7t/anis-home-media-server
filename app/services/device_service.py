"""Client device tracking, network telemetry, and watch history service."""
import hashlib
import ipaddress
import json
import logging
import re
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from flask import request

from app import config
from app.db import get_db, value
from app.utils.filesystem import safe_path
from app.utils.formatting import clean_title

logger = logging.getLogger(__name__)


IQOO_MODELS = {
    "I2011": "iQOO 7",
    "I2012": "iQOO 7 Legend",
    "I2126": "iQOO 9 Pro",
    "I2202": "iQOO Neo 7",
    "I2208": "iQOO Z7",
    "I2209": "iQOO Z7 Pro",
    "I2217": "iQOO Neo 7 Pro",
    "I2220": "iQOO 11",
    "I2301": "iQOO 12",
    "I2307": "iQOO Z9",
    "I2308": "iQOO Z9x",
    "I2401": "iQOO 13",
    "V2202": "iQOO Neo 7",
    "V2164A": "iQOO 9",
    "V2170A": "iQOO 9 Pro",
    "V2231A": "iQOO 11",
    "V2241A": "iQOO Neo 8",
    "V2307A": "iQOO 12",
    "V2324A": "iQOO Neo 9",
    "V2339A": "iQOO Neo 9 Pro",
}


def resolve_device_make_model(model_raw, ua_string=""):
    """Resolve raw model code / Client Hints into friendly make and model label."""
    clean_model = (model_raw or "").strip('"\' ').strip()
    ua = ua_string or ""

    # Ignore Chromium UA-reduction dummy placeholder 'K'
    if clean_model in ("K", "Unknown", ""):
        clean_model = None

    if clean_model:
        upper_code = clean_model.upper()
        if upper_code in IQOO_MODELS:
            name = f"Vivo {IQOO_MODELS[upper_code]}"
            return name, f"{IQOO_MODELS[upper_code]} ({clean_model})"
        if re.match(r'^I\d{4}$', upper_code):
            return "Vivo iQOO", f"iQOO ({clean_model})"
        if re.search(r'iQOO', clean_model, re.IGNORECASE):
            return f"Vivo {clean_model}", clean_model
        if re.match(r'^V\d{4}[A-Z]?$', upper_code):
            return "Vivo", f"Vivo ({clean_model})"

        # Samsung models
        if upper_code.startswith("SM-"):
            if upper_code.startswith("SM-S9"):
                return "Samsung Galaxy S Ultra/Plus", clean_model
            elif upper_code.startswith("SM-S"):
                return "Samsung Galaxy S", clean_model
            elif upper_code.startswith("SM-A"):
                return "Samsung Galaxy A", clean_model
            elif upper_code.startswith("SM-M"):
                return "Samsung Galaxy M", clean_model
            elif upper_code.startswith("SM-F"):
                return "Samsung Galaxy Z Fold/Flip", clean_model
            elif upper_code.startswith("SM-N"):
                return "Samsung Galaxy Note", clean_model
            elif upper_code.startswith(("SM-T", "SM-X")):
                return "Samsung Galaxy Tab", clean_model
            return "Samsung Galaxy", clean_model

        # Google Pixel
        if re.search(r'Pixel', clean_model, re.IGNORECASE):
            return f"Google {clean_model}", clean_model

        # OnePlus
        if re.search(r'OnePlus', clean_model, re.IGNORECASE) or upper_code.startswith(("KB20", "IN20", "NE22", "CPH2413", "CPH2449", "CPH2573")):
            return f"OnePlus ({clean_model})", clean_model

        # Xiaomi / Redmi / POCO
        if re.search(r'Redmi', clean_model, re.IGNORECASE):
            return f"Xiaomi {clean_model}", clean_model
        if re.search(r'POCO', clean_model, re.IGNORECASE):
            return f"POCO {clean_model}", clean_model
        if re.match(r'^(?:2[1-5]\d{2}|M2\d{3})', upper_code):
            return "Xiaomi / Redmi", clean_model

        # Realme
        if upper_code.startswith("RMX"):
            return "Realme", f"Realme ({clean_model})"

        # Motorola
        if upper_code.startswith(("MOTO", "XT")):
            return "Motorola", clean_model

        return clean_model, clean_model

    # If no model provided, try extracting from UA if not reduced
    if ua:
        if re.search(r'iPhone', ua, re.IGNORECASE):
            return "Apple iPhone", "iPhone"
        if re.search(r'iPad', ua, re.IGNORECASE):
            return "Apple iPad", "iPad"
        if re.search(r'Macintosh', ua, re.IGNORECASE):
            return "Apple Mac", "Mac"

        # Check for Android model in UA: e.g. '; <model> Build/' or '; Android...; <model>)'
        m_bld = re.search(r';\s*([^;]+?)\s+Build/', ua)
        if m_bld:
            cand = m_bld.group(1).strip()
            if cand != 'K':
                return resolve_device_make_model(cand)

        m_paren = re.search(r';\s*Android[^;]*;\s*([^;)]+)\)', ua)
        if m_paren:
            cand = m_paren.group(1).strip()
            if cand != 'K':
                return resolve_device_make_model(cand)

        if re.search(r'Android', ua, re.IGNORECASE):
            return "Android Smartphone", "Smartphone"

    return "Generic Client", "Unknown Device"


def resolve_device_os(ua_os, platform_raw="", platform_ver_raw=""):
    """Resolve accurate OS name and version using Client Hints where available."""
    plat = (platform_raw or "").strip('"\' ').strip().lower()
    ver = (platform_ver_raw or "").strip('"\' ').strip()

    if "android" in plat or "android" in (ua_os or "").lower():
        if ver:
            major = ver.split('.')[0]
            if major.isdigit() and int(major) >= 5:
                return f"Android {major}"
        return ua_os or "Android"

    if "windows" in plat or "windows" in (ua_os or "").lower():
        if ver:
            major = ver.split('.')[0]
            if major.isdigit():
                return "Windows 11" if int(major) >= 13 else "Windows 10"
        return ua_os or "Windows"

    if "macos" in plat or "mac" in (ua_os or "").lower():
        if ver:
            major = ver.split('.')[0]
            return f"macOS {major}"
        return ua_os or "macOS"

    return ua_os or "Unknown OS"


def parse_user_agent(ua_string, req=None):
    """Parse User-Agent string and Client Hints to extract device type, OS, browser, make, and model."""
    ch_model = None
    ch_platform = None
    ch_platform_ver = None
    ch_mobile = None

    if req is not None:
        ch_model = req.headers.get('Sec-CH-UA-Model')
        ch_platform = req.headers.get('Sec-CH-UA-Platform')
        ch_platform_ver = req.headers.get('Sec-CH-UA-Platform-Version')
        ch_mobile = req.headers.get('Sec-CH-UA-Mobile')

    if not ua_string:
        device_name, device_model = resolve_device_make_model(ch_model)
        device_os = resolve_device_os("Unknown OS", ch_platform, ch_platform_ver)
        return {
            "device_type": "Mobile" if ch_mobile == '?1' else "Other",
            "device_os": device_os,
            "browser": "Unknown Browser",
            "device_name": device_name,
            "device_model": device_model,
        }

    ua = ua_string
    device_type = "Desktop"
    device_os = "Unknown OS"
    browser = "Unknown Browser"
    device_name = "Desktop PC"
    device_model = None

    # --- 1. Detect Smart TV / Console ---
    if re.search(r'AppleTV|Apple\s*TV', ua, re.IGNORECASE):
        device_type = "Smart TV"
        device_os = "tvOS"
        device_name = "Apple TV"
        device_model = "Apple TV"
    elif re.search(r'Tizen', ua, re.IGNORECASE):
        device_type = "Smart TV"
        m_tv = re.search(r'Tizen\s*([0-9.]+)', ua, re.IGNORECASE)
        device_os = f"Tizen OS {m_tv.group(1)}" if m_tv else "Tizen OS"
        device_name = "Samsung Smart TV"
        device_model = "Samsung Tizen"
    elif re.search(r'Web0S|webOS', ua, re.IGNORECASE):
        device_type = "Smart TV"
        device_os = "LG webOS"
        device_name = "LG Smart TV"
        device_model = "LG webOS"
    elif re.search(r'PlayStation', ua, re.IGNORECASE):
        device_type = "Console"
        device_os = "PlayStation"
        device_name = "Sony PlayStation"
        device_model = "PlayStation"
    elif re.search(r'Xbox', ua, re.IGNORECASE):
        device_type = "Console"
        device_os = "Xbox OS"
        device_name = "Microsoft Xbox"
        device_model = "Xbox"
    elif re.search(r'Roku|SmartTV|GoogleTV|AndroidTV|HbbTV|CrKey', ua, re.IGNORECASE):
        device_type = "Smart TV"
        device_os = "Smart TV OS"
        device_name = "Smart TV / Streaming Stick"
        device_model = "Streaming Device"

    # --- 2. Detect Mobile / Tablet / Desktop OS ---
    elif re.search(r'iPad', ua, re.IGNORECASE):
        device_type = "Tablet"
        m_ver = re.search(r'OS\s+([0-9_]+)', ua)
        ver_str = m_ver.group(1).replace('_', '.') if m_ver else ""
        device_os = f"iPadOS {ver_str}".strip()
        device_name = "Apple iPad"
        device_model = "iPad"
    elif re.search(r'iPhone', ua, re.IGNORECASE):
        device_type = "Mobile"
        m_ver = re.search(r'iPhone\s+OS\s+([0-9_]+)', ua)
        ver_str = m_ver.group(1).replace('_', '.') if m_ver else ""
        device_os = f"iOS {ver_str}".strip()
        device_name = "Apple iPhone"
        device_model = "iPhone"
    elif re.search(r'Android', ua, re.IGNORECASE):
        m_ver = re.search(r'Android\s+([0-9.]+)', ua)
        ver_str = m_ver.group(1) if m_ver else ""
        device_os = f"Android {ver_str}".strip()
        # Android Tablet vs Mobile phone: Mobile keyword indicates phone
        if re.search(r'Mobile', ua, re.IGNORECASE) or ch_mobile == '?1':
            device_type = "Mobile"
            d_name, d_model = resolve_device_make_model(ch_model, ua)
            device_name = d_name or "Android Smartphone"
            device_model = d_model
        else:
            device_type = "Tablet"
            device_name = "Android Tablet"
            device_model = "Tablet"
    elif re.search(r'Windows NT', ua, re.IGNORECASE):
        device_type = "Desktop"
        m_win = re.search(r'Windows NT\s*([0-9.]+)', ua)
        nt_ver = m_win.group(1) if m_win else ""
        win_names = {
            "10.0": "Windows 10/11",
            "6.3": "Windows 8.1",
            "6.2": "Windows 8",
            "6.1": "Windows 7",
        }
        device_os = win_names.get(nt_ver, f"Windows NT {nt_ver}")
        device_name = "Windows PC"
        device_model = "PC"
    elif re.search(r'Macintosh|Mac OS X', ua, re.IGNORECASE):
        device_type = "Desktop"
        m_mac = re.search(r'Mac OS X\s*([0-9_]+)', ua)
        ver_str = m_mac.group(1).replace('_', '.') if m_mac else ""
        device_os = f"macOS {ver_str}".strip()
        device_name = "Apple Mac"
        device_model = "Mac"
    elif re.search(r'CrOS', ua, re.IGNORECASE):
        device_type = "Desktop"
        device_os = "ChromeOS"
        device_name = "Chromebook"
        device_model = "Chromebook"
    elif re.search(r'Linux', ua, re.IGNORECASE):
        device_type = "Desktop"
        device_os = "Linux"
        device_name = "Linux PC"
        device_model = "PC"

    # --- 3. Detect Browser ---
    if re.search(r'Edg(?:e|A|iOS)?/([0-9.]+)', ua):
        m_br = re.search(r'Edg(?:e|A|iOS)?/([0-9.]+)', ua)
        browser = f"Edge {m_br.group(1).split('.')[0]}"
    elif re.search(r'SamsungBrowser/([0-9.]+)', ua):
        m_br = re.search(r'SamsungBrowser/([0-9.]+)', ua)
        browser = f"Samsung Internet {m_br.group(1).split('.')[0]}"
    elif re.search(r'Chrome/([0-9.]+)|CriOS/([0-9.]+)', ua):
        m_br = re.search(r'(?:Chrome|CriOS)/([0-9.]+)', ua)
        browser = f"Chrome {m_br.group(1).split('.')[0]}"
    elif re.search(r'Firefox/([0-9.]+)|FxiOS/([0-9.]+)', ua):
        m_br = re.search(r'(?:Firefox|FxiOS)/([0-9.]+)', ua)
        browser = f"Firefox {m_br.group(1).split('.')[0]}"
    elif re.search(r'Version/([0-9.]+).*Safari', ua):
        m_br = re.search(r'Version/([0-9.]+).*Safari', ua)
        browser = f"Safari {m_br.group(1).split('.')[0]}"
    elif re.search(r'Safari', ua) and not re.search(r'Chrome', ua):
        browser = "Safari"
    elif re.search(r'curl|python-requests|wget', ua, re.IGNORECASE):
        browser = ua.split('/')[0]
        device_type = "Tool/Bot"
        device_name = "Automated Client"
        device_model = "Bot"

    # Apply Client Hints overrides if available
    device_os = resolve_device_os(device_os, ch_platform, ch_platform_ver)
    if ch_model:
        d_name, d_model = resolve_device_make_model(ch_model, ua)
        if d_name and d_name != "Android Smartphone":
            device_name = d_name
        if d_model:
            device_model = d_model

    return {
        "device_type": device_type,
        "device_os": device_os,
        "browser": browser,
        "device_name": device_name,
        "device_model": device_model,
    }


def is_private_ip(ip_str):
    """Return True if IP is in RFC 1918 or loopback subnet."""
    if not ip_str:
        return False
    try:
        ip_obj = ipaddress.ip_address(ip_str)
        return ip_obj.is_private or ip_obj.is_loopback
    except ValueError:
        return False


def classify_connection(req):
    """Classify connection channel: Cloudflare Tunnel, Localhost, LAN, or Direct."""
    cf_connecting_ip = req.headers.get('CF-Connecting-IP')
    cf_ray = req.headers.get('CF-Ray')
    host = req.headers.get('Host', '')
    x_forwarded_for = req.headers.get('X-Forwarded-For')
    remote_addr = req.remote_addr or '127.0.0.1'

    # 1. Cloudflare Quick Tunnel (*.trycloudflare.com) or CF edge proxy
    if cf_connecting_ip or cf_ray or ('trycloudflare.com' in host.lower()):
        client_ip = (
            cf_connecting_ip
            or (x_forwarded_for.split(',')[0].strip() if x_forwarded_for else remote_addr)
        )
        return {
            "connection_type": "Internet (Cloudflare Tunnel)",
            "client_ip": client_ip,
            "public_ip": client_ip,
            "is_cloudflare": True,
        }

    # 2. Localhost
    if remote_addr in ('127.0.0.1', '::1', 'localhost'):
        return {
            "connection_type": "Localhost (127.0.0.1)",
            "client_ip": remote_addr,
            "public_ip": None,
            "is_cloudflare": False,
        }

    # 3. Local Network (LAN)
    if is_private_ip(remote_addr):
        return {
            "connection_type": "Local Network (LAN)",
            "client_ip": remote_addr,
            "public_ip": None,
            "is_cloudflare": False,
        }

    # 4. Direct Internet connection
    return {
        "connection_type": "Internet (Direct)",
        "client_ip": remote_addr,
        "public_ip": remote_addr,
        "is_cloudflare": False,
    }


def resolve_mac_address(client_ip, connection_type):
    """Resolve hardware MAC address via /proc/net/arp for LAN, or route boundary label."""
    if connection_type == "Localhost (127.0.0.1)" or client_ip in ('127.0.0.1', '::1', 'localhost'):
        return "Local Loopback (lo)"

    if "Internet" in connection_type or "Cloudflare" in connection_type:
        return "WAN Proxy (Not L2 routable)"

    # LAN lookup via /proc/net/arp
    arp_file = Path("/proc/net/arp")
    if arp_file.is_file():
        try:
            for line in arp_file.read_text(errors="replace").splitlines()[1:]:
                parts = line.split()
                if len(parts) >= 4 and parts[0] == client_ip:
                    hw_flags = parts[2]
                    hw_addr = parts[3].upper()
                    if hw_flags != "0x0" and hw_addr != "00:00:00:00:00:00":
                        return hw_addr
        except Exception as e:
            logger.debug(f"ARP table read failed: {e}")

    return "LAN (ARP Pending)"


def lookup_geoip_and_isp(ip, connection_type):
    """Lookup ISP, organization, city, and country with local caching."""
    if connection_type == "Localhost (127.0.0.1)":
        return {
            "isp": "Local Loopback",
            "city": "Localhost",
            "country": "Local System",
        }

    if connection_type == "Local Network (LAN)":
        return {
            "isp": "Local Network (LAN)",
            "city": "Home Network",
            "country": "Local Subnet",
        }

    if not ip or is_private_ip(ip):
        return {
            "isp": "Private Network",
            "city": "LAN",
            "country": "Internal",
        }

    # Check ip_cache in database
    try:
        db = get_db()
        row = db.execute("SELECT * FROM ip_cache WHERE ip=?", (ip,)).fetchone()
        db.close()
        if row and value(row, 'isp'):
            return {
                "isp": value(row, 'isp'),
                "city": value(row, 'city') or "Unknown",
                "country": value(row, 'country') or "Unknown",
            }
    except Exception as e:
        logger.debug(f"ip_cache read error: {e}")

    # Fallback default values
    default_res = {
        "isp": "Cloudflare / External ISP",
        "city": "Internet",
        "country": "Remote",
    }

    try:
        from flask import current_app
        if current_app and current_app.config.get('TESTING'):
            return default_res
    except Exception:
        pass

    # Query external API with short timeout
    try:
        url = f"http://ip-api.com/json/{ip}?fields=status,message,country,city,isp,org"
        req = urllib.request.Request(url, headers={"User-Agent": "MediaServerDeviceTracker/1.0"})
        with urllib.request.urlopen(req, timeout=1.5) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            if data.get('status') == 'success':
                isp_val = data.get('isp') or data.get('org') or "External ISP"
                city_val = data.get('city') or "Remote"
                country_val = data.get('country') or "Internet"

                # Persist into ip_cache
                db = get_db()
                db.execute(
                    "INSERT INTO ip_cache(ip, isp, org, city, country, updated_at) "
                    "VALUES(?, ?, ?, ?, ?, CURRENT_TIMESTAMP) "
                    "ON CONFLICT(ip) DO UPDATE SET "
                    "isp=excluded.isp, org=excluded.org, city=excluded.city, country=excluded.country, updated_at=CURRENT_TIMESTAMP",
                    (ip, isp_val, data.get('org') or isp_val, city_val, country_val)
                )
                db.commit()
                db.close()
                return {
                    "isp": isp_val,
                    "city": city_val,
                    "country": country_val,
                }
    except Exception as e:
        logger.debug(f"ip-api lookup error for {ip}: {e}")

    return default_res


def get_or_create_device_id(req):
    """Retrieve existing device ID from cookie/header or generate a deterministic one."""
    cookie_id = req.cookies.get('ms_device_id')
    if cookie_id and cookie_id.startswith('dev_'):
        return cookie_id, False

    header_id = req.headers.get('X-Device-Id')
    if header_id and header_id.startswith('dev_'):
        return header_id, False

    # Deterministic fallback based on Client IP + User Agent hash
    conn_info = classify_connection(req)
    ip = conn_info.get('client_ip') or req.remote_addr or '127.0.0.1'
    ua = req.headers.get('User-Agent', '')
    seed = f"{ip}|{ua}"
    hash_prefix = hashlib.sha256(seed.encode('utf-8')).hexdigest()[:16]
    return f"dev_{hash_prefix}", True


def register_device_request(req):
    """Process incoming request, register or update device telemetry, and return (device_id, is_new)."""
    device_id, is_new = get_or_create_device_id(req)
    ua_str = req.headers.get('User-Agent', '')
    ua_parsed = parse_user_agent(ua_str, req=req)
    conn_info = classify_connection(req)
    client_ip = conn_info['client_ip']
    public_ip = conn_info['public_ip']
    conn_type = conn_info['connection_type']

    mac = resolve_mac_address(client_ip, conn_type)
    geo = lookup_geoip_and_isp(public_ip or client_ip, conn_type)

    try:
        db = get_db()
        db.execute(
            """
            INSERT INTO devices(
                device_id, custom_name, device_name, device_type, device_os,
                browser, user_agent, connection_type, client_ip, public_ip,
                mac_address, isp, city, country, first_seen, last_seen, device_model
            ) VALUES(?, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, ?)
            ON CONFLICT(device_id) DO UPDATE SET
                device_name=CASE
                    WHEN excluded.device_name NOT IN ('Android Smartphone', 'Desktop PC', 'Generic Client') THEN excluded.device_name
                    WHEN devices.device_name IS NOT NULL AND devices.device_name NOT IN ('Android Smartphone', 'Desktop PC', 'Generic Client') THEN devices.device_name
                    ELSE excluded.device_name
                END,
                device_model=COALESCE(NULLIF(excluded.device_model, ''), devices.device_model),
                device_type=excluded.device_type,
                device_os=CASE
                    WHEN excluded.device_os LIKE 'Android %' AND excluded.device_os != 'Android 10' THEN excluded.device_os
                    WHEN devices.device_os LIKE 'Android %' AND devices.device_os != 'Android 10' THEN devices.device_os
                    ELSE excluded.device_os
                END,
                browser=excluded.browser,
                user_agent=excluded.user_agent,
                connection_type=excluded.connection_type,
                client_ip=excluded.client_ip,
                public_ip=excluded.public_ip,
                mac_address=excluded.mac_address,
                isp=excluded.isp,
                city=excluded.city,
                country=excluded.country,
                last_seen=CURRENT_TIMESTAMP
            """,
            (
                device_id,
                ua_parsed['device_name'],
                ua_parsed['device_type'],
                ua_parsed['device_os'],
                ua_parsed['browser'],
                ua_str,
                conn_type,
                client_ip,
                public_ip,
                mac,
                geo['isp'],
                geo['city'],
                geo['country'],
                ua_parsed.get('device_model'),
            )
        )
        db.commit()
        db.close()
    except Exception as e:
        logger.warning(f"Error registering device {device_id}: {e}")

    return device_id, is_new


def record_device_heartbeat(req):
    """Record a lightweight keepalive heartbeat from a client device."""
    device_id, _ = get_or_create_device_id(req)
    db = get_db()
    try:
        cur = db.execute(
            "UPDATE devices SET last_seen=CURRENT_TIMESTAMP WHERE device_id=?",
            (device_id,)
        )
        if cur.rowcount == 0:
            db.close()
            register_device_request(req)
            return device_id
        db.commit()
        return device_id
    finally:
        try:
            db.close()
        except Exception:
            pass


def update_device_client_hints(device_id, model=None, platform=None, platform_version=None):
    """Update device make, model, and OS based on high-entropy Client Hints."""
    if not device_id:
        return False

    db = get_db()
    try:
        row = db.execute("SELECT * FROM devices WHERE device_id=?", (device_id,)).fetchone()
        if not row:
            return False

        ua_str = row['user_agent'] or ''
        current_os = row['device_os'] or ''
        current_name = row['device_name'] or ''
        current_model = row['device_model'] or ''

        # Resolve model
        resolved_name, resolved_model = resolve_device_make_model(model, ua_str)
        if not resolved_name or resolved_name == 'Android Smartphone':
            resolved_name = current_name
        if not resolved_model:
            resolved_model = current_model

        # Resolve OS
        resolved_os = resolve_device_os(current_os, platform or '', platform_version or '')

        db.execute(
            """
            UPDATE devices SET
                device_name = COALESCE(?, device_name),
                device_model = COALESCE(?, device_model),
                device_os = COALESCE(?, device_os),
                last_seen = CURRENT_TIMESTAMP
            WHERE device_id = ?
            """,
            (resolved_name, resolved_model, resolved_os, device_id)
        )
        db.commit()
        return True
    finally:
        db.close()


def record_device_watch(device_id, filename, position, duration):
    """Record or update watch progress and history for a specific device."""
    if not device_id or not filename:
        return

    try:
        pos = max(0.0, float(position))
        dur = max(0.0, float(duration))
    except (TypeError, ValueError):
        return

    completed = 1 if (dur > 0 and (pos >= dur * 0.9 or (dur - pos) <= 15)) else 0

    try:
        db = get_db()
        db.execute(
            """
            INSERT INTO device_watch_history(
                device_id, filename, position, duration, completed, last_watched
            ) VALUES(?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
            ON CONFLICT(device_id, filename) DO UPDATE SET
                position=excluded.position,
                duration=excluded.duration,
                completed=excluded.completed,
                last_watched=CURRENT_TIMESTAMP
            """,
            (device_id, filename, pos, dur, completed)
        )
        db.commit()
        db.close()
    except Exception as e:
        logger.warning(f"Error recording device watch for {device_id}: {e}")


def format_time_ago(ts_str):
    """Format an ISO/SQLite timestamp into a human-friendly relative string."""
    if not ts_str:
        return "Unknown"
    try:
        # SQLite timestamps are UTC 'YYYY-MM-DD HH:MM:SS'
        clean_ts = ts_str.replace('T', ' ').split('.')[0]
        dt = datetime.strptime(clean_ts, '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc)
        now = datetime.now(timezone.utc)
        diff = max(0.0, (now - dt).total_seconds())
        if diff < 60:
            return "Just now"
        elif diff < 3600:
            mins = int(diff // 60)
            return f"{mins}m ago"
        elif diff < 86400:
            hours = int(diff // 3600)
            return f"{hours}h ago"
        else:
            days = int(diff // 86400)
            return f"{days}d ago"
    except Exception:
        return ts_str


def format_clock_time(seconds):
    """Format seconds into HH:MM:SS or MM:SS."""
    try:
        s = int(seconds or 0)
        h = s // 3600
        m = (s % 3600) // 60
        sec = s % 60
        if h > 0:
            return f"{h}:{m:02d}:{sec:02d}"
        return f"{m:02d}:{sec:02d}"
    except Exception:
        return "0:00"


def get_all_devices(current_device_id=None):
    """Retrieve all recorded devices with their network metadata, recent watch, and history."""
    db = get_db()
    try:
        dev_rows = db.execute("SELECT * FROM devices ORDER BY last_seen DESC").fetchall()
        devices = []
        now = datetime.now(timezone.utc)

        for d in dev_rows:
            dev_id = d['device_id']
            last_seen_str = d['last_seen'] or ''
            is_active = False
            try:
                clean_ts = last_seen_str.replace('T', ' ').split('.')[0]
                dt = datetime.strptime(clean_ts, '%Y-%m-%d %H:%M:%S').replace(tzinfo=timezone.utc)
                diff = max(0.0, (now - dt).total_seconds())
                is_active = (diff <= 180)  # Active if seen in last 3 minutes (180s)
            except Exception:
                is_active = False

            # Query watch history for this device
            hist_rows = db.execute(
                """
                SELECT h.*, m.title, m.year, m.tmdb_id, m.poster_path
                FROM device_watch_history h
                LEFT JOIN movies m ON h.filename = m.filename
                WHERE h.device_id = ?
                ORDER BY h.last_watched DESC
                """,
                (dev_id,)
            ).fetchall()

            watch_history = []
            for h in hist_rows:
                fname = h['filename']
                pos = h['position']
                dur = h['duration']
                pct = min(100.0, round((pos / dur * 100), 1)) if dur > 0 else 0.0

                # Determine poster
                poster_url = None
                if h['tmdb_id'] and (config.POSTER_CACHE / f"{h['tmdb_id']}.jpg").is_file():
                    poster_url = f"/tmdb-poster/{h['tmdb_id']}"
                else:
                    # check local poster
                    p_file = safe_path(fname)
                    for ext in config.POSTER_EXTENSIONS:
                        c_poster = p_file.with_suffix(ext)
                        if c_poster.is_file():
                            poster_url = f"/poster/{fname}"
                            break

                watch_history.append({
                    "filename": fname,
                    "title": h['title'] or clean_title(Path(fname).name),
                    "year": h['year'] or "",
                    "position": pos,
                    "duration": dur,
                    "position_str": format_clock_time(pos),
                    "duration_str": format_clock_time(dur),
                    "percent": pct,
                    "completed": bool(h['completed']),
                    "last_watched": h['last_watched'],
                    "last_watched_ago": format_time_ago(h['last_watched']),
                    "poster_url": poster_url,
                })

            recent_watch = watch_history[0] if watch_history else None

            # Choose best device icon
            dtype = d['device_type']
            if dtype == 'Mobile':
                icon = '📱'
            elif dtype == 'Tablet':
                icon = '📟'
            elif dtype == 'Smart TV':
                icon = '📺'
            elif dtype == 'Console':
                icon = '🎮'
            elif dtype == 'Tool/Bot':
                icon = '🤖'
            else:
                icon = '💻'

            display_name = d['custom_name'] or d['device_name'] or "Unknown Device"
            model_val = d['device_model'] if 'device_model' in d.keys() else None

            devices.append({
                "device_id": dev_id,
                "custom_name": d['custom_name'],
                "device_name": d['device_name'],
                "device_model": model_val,
                "display_name": display_name,
                "device_type": d['device_type'],
                "device_icon": icon,
                "device_os": d['device_os'],
                "browser": d['browser'],
                "user_agent": d['user_agent'],
                "connection_type": d['connection_type'],
                "client_ip": d['client_ip'],
                "public_ip": d['public_ip'],
                "mac_address": d['mac_address'],
                "isp": d['isp'],
                "city": d['city'],
                "country": d['country'],
                "first_seen": d['first_seen'],
                "last_seen": d['last_seen'],
                "last_seen_ago": format_time_ago(d['last_seen']),
                "is_active": is_active,
                "is_current": (dev_id == current_device_id),
                "recent_watch": recent_watch,
                "watch_history": watch_history,
                "total_watched": len(watch_history),
            })

        # Calculate summary statistics
        total_devices = len(devices)
        active_now = sum(1 for d in devices if d['is_active'])
        offline_count = total_devices - active_now
        cf_count = sum(1 for d in devices if 'Cloudflare' in d['connection_type'])
        lan_count = sum(1 for d in devices if 'LAN' in d['connection_type'])
        local_count = sum(1 for d in devices if 'Localhost' in d['connection_type'])

        stats = {
            "total_devices": total_devices,
            "active_now": active_now,
            "offline_count": offline_count,
            "cloudflare_count": cf_count,
            "lan_count": lan_count,
            "localhost_count": local_count,
        }

        return devices, stats
    finally:
        db.close()


def rename_device(device_id, new_name):
    """Update custom friendly name for a device."""
    clean_name = (new_name or "").strip()
    if not clean_name:
        clean_name = None
    db = get_db()
    try:
        db.execute("UPDATE devices SET custom_name=? WHERE device_id=?", (clean_name, device_id))
        db.commit()
        return True
    finally:
        db.close()


def delete_device(device_id):
    """Permanently delete a device and its watch history."""
    db = get_db()
    try:
        db.execute("DELETE FROM device_watch_history WHERE device_id=?", (device_id,))
        db.execute("DELETE FROM devices WHERE device_id=?", (device_id,))
        db.commit()
        return True
    finally:
        db.close()
