# ADR-002: gomplate + sops exec-env によるテンプレート管理

- **Status**: accepted
- **Date**: 2025-04-01

## Context

Vaultwarden の Quadlet ファイルに Tailscale authkey やドメイン名を埋め込む必要がある。`sed` による置換は脆弱で、秘匿値の管理が複雑になる。

## Decision

`.tmpl` ファイルを Go テンプレート構文 (gomplate) で記述し、deploy 時に `sops exec-env` で secrets を環境変数に注入、`tailscale status` で MagicDNS suffix を取得して gomplate で展開する。

## Consequences

- 良い面: 秘匿値がリポジトリに平文で残らない。テンプレート構文が宣言的で可読性が高い
- 悪い面: gomplate + sops の両方が必要（Nix で解決済み）
