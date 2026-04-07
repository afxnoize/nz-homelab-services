# ADR-004: systemd service における kopia パス解決

- **Status**: accepted
- **Date**: 2025-04-01

## Context

Nix で管理された kopia は `/nix/store/` 配下にあり、`/usr/bin/env kopia` では PATH が通らない。systemd user service から kopia を呼び出す必要がある。

## Decision

`just backup timer-on` 実行時に `which kopia` で nix store 内のフルパスを解決し、service ファイルに埋め込む。

## Consequences

- 良い面: Nix 環境でも systemd から確実に kopia を実行できる
- 悪い面: kopia のバージョンを更新したら timer-on を再実行する必要がある
