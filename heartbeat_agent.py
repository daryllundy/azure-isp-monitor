#!/usr/bin/env python3
"""
ISP Monitor Heartbeat Agent

This script sends periodic heartbeat pings to the Azure Function to monitor
internet connectivity. Run this on a device that should be monitored.

Usage:
    python3 heartbeat_agent.py [options]

Options:
    --url URL           Function endpoint URL (default: from HEARTBEAT_URL env var)
    --device NAME       Device identifier (default: from HEARTBEAT_DEVICE env var or hostname)
    --interval SECONDS  Ping interval in seconds (default: 60)
    --daemon            Run as a daemon process
    --once              Send a single ping and exit
    --verbose           Enable verbose logging

Examples:
    # Send one ping
    python3 heartbeat_agent.py --url https://your-func.azurewebsites.net/api/ping --device dl-home --once

    # Run continuously every 60 seconds
    python3 heartbeat_agent.py --url https://your-func.azurewebsites.net/api/ping --device dl-home

    # Run as daemon with custom interval
    python3 heartbeat_agent.py --interval 120 --daemon --verbose
"""

import argparse
import json
import os
import socket
import ssl
import sys
import time
from datetime import datetime
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError


def get_device_name():
    """Get device name from environment or hostname."""
    return os.environ.get('HEARTBEAT_DEVICE', socket.gethostname())


def get_endpoint_url():
    """Get endpoint URL from environment variable."""
    return os.environ.get('HEARTBEAT_URL', '')


def send_ping(url, device_name, note='', verbose=False):
    """
    Send a heartbeat ping to the Azure Function.

    Args:
        url: Function endpoint URL
        device_name: Device identifier
        note: Optional note to include
        verbose: Enable verbose logging

    Returns:
        bool: True if successful, False otherwise
    """
    payload = {
        'device': device_name,
        'note': note
    }

    headers = {
        'Content-Type': 'application/json',
        'User-Agent': 'ISP-Monitor-Heartbeat-Agent/1.0'
    }

    try:
        data = json.dumps(payload).encode('utf-8')
        req = Request(url, data=data, headers=headers, method='POST')

        if verbose:
            print(f"[{datetime.now().isoformat()}] Sending ping to {url}")
            print(f"  Device: {device_name}")
            print(f"  Note: {note}")

        # Create SSL context that uses system certificates
        ssl_context = ssl.create_default_context()

        with urlopen(req, timeout=10, context=ssl_context) as response:
            response_data = response.read().decode('utf-8')
            status_code = response.status

            if verbose:
                print(f"  Response: {status_code} - {response_data}")

            if status_code == 200:
                if not verbose:
                    print(f"[{datetime.now().isoformat()}] ✓ Ping sent successfully ({device_name})")
                return True
            else:
                print(f"[{datetime.now().isoformat()}] ⚠ Unexpected status: {status_code}", file=sys.stderr)
                return False

    except HTTPError as e:
        print(f"[{datetime.now().isoformat()}] ✗ HTTP Error {e.code}: {e.reason}", file=sys.stderr)
        return False
    except URLError as e:
        print(f"[{datetime.now().isoformat()}] ✗ URL Error: {e.reason}", file=sys.stderr)
        return False
    except Exception as e:
        print(f"[{datetime.now().isoformat()}] ✗ Error: {str(e)}", file=sys.stderr)
        return False


def run_daemon(url, device_name, interval, verbose=False):
    """
    Run the heartbeat agent as a daemon.

    Args:
        url: Function endpoint URL
        device_name: Device identifier
        interval: Seconds between pings
        verbose: Enable verbose logging
    """
    print(f"Starting heartbeat daemon for device '{device_name}'")
    print(f"Target: {url}")
    print(f"Interval: {interval} seconds")
    print(f"Press Ctrl+C to stop\n")

    consecutive_failures = 0
    max_failures = 5

    try:
        while True:
            note = f"daemon ping #{time.time():.0f}"
            success = send_ping(url, device_name, note, verbose)

            if success:
                consecutive_failures = 0
            else:
                consecutive_failures += 1
                if consecutive_failures >= max_failures:
                    print(f"\n⚠ Warning: {consecutive_failures} consecutive failures!", file=sys.stderr)
                    print(f"Check your internet connection and function endpoint.\n", file=sys.stderr)

            time.sleep(interval)

    except KeyboardInterrupt:
        print(f"\n[{datetime.now().isoformat()}] Heartbeat daemon stopped by user")
        sys.exit(0)


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='Send heartbeat pings to Azure ISP Monitor function',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__
    )

    parser.add_argument(
        '--url',
        type=str,
        default=get_endpoint_url(),
        help='Function endpoint URL (default: HEARTBEAT_URL env var)'
    )

    parser.add_argument(
        '--device',
        type=str,
        default=get_device_name(),
        help='Device identifier (default: HEARTBEAT_DEVICE env var or hostname)'
    )

    parser.add_argument(
        '--interval',
        type=int,
        default=60,
        help='Ping interval in seconds (default: 60)'
    )

    parser.add_argument(
        '--daemon',
        action='store_true',
        help='Run as a daemon process'
    )

    parser.add_argument(
        '--once',
        action='store_true',
        help='Send a single ping and exit'
    )

    parser.add_argument(
        '--verbose',
        action='store_true',
        help='Enable verbose logging'
    )

    args = parser.parse_args()

    # Validate URL
    if not args.url:
        print("Error: No URL specified. Use --url or set HEARTBEAT_URL environment variable.", file=sys.stderr)
        sys.exit(1)

    if not args.url.startswith('http'):
        print("Error: URL must start with http:// or https://", file=sys.stderr)
        sys.exit(1)

    # Single ping mode
    if args.once:
        success = send_ping(args.url, args.device, note='single ping', verbose=args.verbose)
        sys.exit(0 if success else 1)

    # Daemon mode
    if args.daemon:
        run_daemon(args.url, args.device, args.interval, args.verbose)
    else:
        # Default: single ping
        success = send_ping(args.url, args.device, note='manual ping', verbose=args.verbose)
        sys.exit(0 if success else 1)


if __name__ == '__main__':
    main()
