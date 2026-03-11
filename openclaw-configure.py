#!/usr/bin/env python3
import json
from pathlib import Path

CFG = Path('/root/.openclaw/openclaw.json')
PROVIDER = 'default'
WORKSPACE = '/root/.openclaw'


def prompt(name: str, default: str = '') -> str:
    suffix = f' [{default}]' if default else ''
    v = input(f'{name}{suffix}: ').strip()
    return v or default


def main() -> int:
    if not CFG.exists():
        print(f'config not found: {CFG}')
        return 1

    cfg = json.loads(CFG.read_text())
    providers = cfg.setdefault('models', {}).setdefault('providers', {})
    provider_cfg = providers.setdefault(PROVIDER, {})

    current_base = provider_cfg.get('baseUrl', '')
    current_key = provider_cfg.get('apiKey', '')
    current_model = ''
    models_list = provider_cfg.get('models') or []
    if models_list and isinstance(models_list, list) and isinstance(models_list[0], dict):
        current_model = models_list[0].get('id', '')

    base_url = prompt('Base URL', current_base)
    api_key = prompt('API key', current_key)
    model_name = prompt('Model name', current_model or 'gpt-5.4')

    cfg.setdefault('models', {})['mode'] = 'merge'
    cfg['models']['providers'] = {PROVIDER: provider_cfg}
    provider_cfg['baseUrl'] = base_url
    provider_cfg['apiKey'] = api_key
    provider_cfg['auth'] = 'api-key'
    provider_cfg['api'] = 'openai-completions'
    provider_cfg['authHeader'] = True
    provider_cfg['models'] = [{
        'id': model_name,
        'name': model_name,
        'reasoning': False,
        'input': ['text'],
        'cost': {'input': 0, 'output': 0, 'cacheRead': 0, 'cacheWrite': 0},
        'contextWindow': 200000,
        'maxTokens': 8192,
        'compat': {'maxTokensField': 'max_tokens'},
    }]

    agents = cfg.setdefault('agents', {}).setdefault('defaults', {})
    agents.setdefault('model', {})['primary'] = f'{PROVIDER}/{model_name}'
    agents['models'] = {f'{PROVIDER}/{model_name}': {}}
    agents['workspace'] = WORKSPACE

    cfg.setdefault('tools', {})['profile'] = 'full'
    cfg.setdefault('messages', {})['ackReactionScope'] = 'group-mentions'
    cfg.setdefault('commands', {}).update({
        'native': 'auto',
        'nativeSkills': 'auto',
        'restart': True,
        'ownerDisplay': 'raw',
    })
    cfg.setdefault('session', {})['dmScope'] = 'per-channel-peer'
    hooks = cfg.setdefault('hooks', {}).setdefault('internal', {})
    hooks['enabled'] = True
    hook_entries = hooks.setdefault('entries', {})
    for name in ('boot-md', 'bootstrap-extra-files', 'command-logger', 'session-memory'):
        hook_entries.setdefault(name, {})['enabled'] = True

    gateway = cfg.setdefault('gateway', {})
    gateway.setdefault('port', 18789)
    gateway['mode'] = 'local'
    gateway['bind'] = 'loopback'
    gateway.setdefault('controlUi', {})['allowedOrigins'] = [
        'http://localhost:18789',
        'http://127.0.0.1:18789',
    ]
    gateway.setdefault('auth', {})['mode'] = 'token'
    gateway['auth'].setdefault('token', 'openclaw-clone-local-token')
    gateway.setdefault('tailscale', {})['mode'] = 'off'
    gateway['tailscale'].setdefault('resetOnExit', False)
    gateway.setdefault('nodes', {})['denyCommands'] = [
        'camera.snap', 'camera.clip', 'screen.record', 'contacts.add', 'calendar.add', 'reminders.add', 'sms.send'
    ]

    CFG.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + '\n')
    print('updated /root/.openclaw/openclaw.json')
    print(json.dumps({
        'provider': PROVIDER,
        'baseUrl': base_url,
        'model': model_name,
        'primary': f'{PROVIDER}/{model_name}',
        'workspace': WORKSPACE,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
