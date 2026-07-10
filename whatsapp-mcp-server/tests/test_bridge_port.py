from __future__ import annotations

import whatsapp


def test_bridge_api_url_uses_8081():
    assert whatsapp.WHATSAPP_API_BASE_URL == "http://localhost:8081/api"
