import json
import re
import time
import azure.functions as func

# Maximum field lengths for validation
MAX_DEVICE_LENGTH = 100
MAX_NOTE_LENGTH = 500

def sanitize_string(value, max_length, default="unknown"):
    """Sanitize and validate string input."""
    if not value or not isinstance(value, str):
        return default

    # Remove control characters and limit length
    sanitized = re.sub(r'[\x00-\x1f\x7f-\x9f]', '', value.strip())
    return sanitized[:max_length] if sanitized else default

def validate_ip(ip_header):
    """Extract and validate IP address from header."""
    if not ip_header:
        return "unknown"

    # X-Forwarded-For may contain multiple IPs, take the first (client IP)
    ip = ip_header.split(',')[0].strip()

    # Basic IP validation (IPv4 or IPv6)
    ipv4_pattern = r'^(\d{1,3}\.){3}\d{1,3}$'
    ipv6_pattern = r'^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$'

    if re.match(ipv4_pattern, ip) or re.match(ipv6_pattern, ip):
        return ip

    return "unknown"

def main(req: func.HttpRequest) -> func.HttpResponse:
    try:
        body = req.get_json()
    except (ValueError, TypeError):
        body = {}

    # Validate and sanitize inputs
    device = sanitize_string(
        body.get("device") or req.headers.get("X-Device"),
        MAX_DEVICE_LENGTH,
        "unknown"
    )

    note = sanitize_string(
        body.get("note"),
        MAX_NOTE_LENGTH,
        ""
    )

    ip = validate_ip(
        req.headers.get("X-Forwarded-For") or req.headers.get("X-Client-IP")
    )

    payload = {
        "ts": int(time.time()),
        "device": device,
        "ip": ip,
        "note": note
    }

    # Log to Application Insights (structured logging)
    print(f"[heartbeat] {json.dumps(payload)}")

    return func.HttpResponse("ok", status_code=200, headers={"Content-Type":"text/plain"})
