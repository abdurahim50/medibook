"""Client address behind the load balancer (MB-004).

The ALB appends the address it received the request from to X-Forwarded-For.
Uvicorn must trust only the ALB's subnets, so it reads the list from the right;
with "*" it took the leftmost entry, which the client writes.
"""
import asyncio

from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware

ALB_SUBNETS = "10.20.0.0/24,10.20.1.0/24"  # the public subnets in infra/network.tf


def client_seen(trusted: str, forwarded_for: bytes, peer: str = "10.20.0.57") -> str:
    seen = {}

    async def app(scope, receive, send):
        seen["host"] = scope["client"][0]

    scope = {"type": "http", "scheme": "http", "client": (peer, 40000),
             "headers": [(b"x-forwarded-for", forwarded_for)]}
    asyncio.run(ProxyHeadersMiddleware(app, trusted_hosts=trusted)(scope, None, None))
    return seen["host"]


def test_forged_leftmost_address_is_ignored():
    # The client sent "X-Forwarded-For: 6.6.6.6"; the ALB appended the real address.
    assert client_seen(ALB_SUBNETS, b"6.6.6.6, 203.0.113.9") == "203.0.113.9"


def test_trusting_everything_would_accept_the_forgery():
    assert client_seen("*", b"6.6.6.6, 203.0.113.9") == "6.6.6.6"


def test_request_not_from_the_alb_keeps_its_own_address():
    assert client_seen(ALB_SUBNETS, b"6.6.6.6", peer="198.51.100.7") == "198.51.100.7"
