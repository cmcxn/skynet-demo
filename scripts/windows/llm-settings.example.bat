@echo off
rem Copy to llm-settings.bat and fill in your own API key. Keep that file private.
set "LLM_API_KEY="
set "LLM_BASE_URL=https://ai.chenmin.org/v1"
set "LLM_MODEL=Qwen3.8-27B"
set "EMBEDDING_BASE_URL=https://ai.chenmin.org/v1"
set "EMBEDDING_MODEL=qwen3-embedding:4b"
rem Optional IPv4 DNS override, e.g. 192.168.1.1 or 192.168.1.1:53.
rem Leave unset to discover the Windows network adapter's DNS server.
rem set "SKYNET_LLM_DNS_SERVER=192.168.1.1"
