# ADR-003: kopia config ファイルの分離

- **Status**: accepted
- **Date**: 2025-04-01

## Context

kopia はデフォルトで `~/.config/kopia/repository.config` を使用する。他の kopia 用途（別のバックアップ先など）と競合する可能性がある。

## Decision

config ファイルを `vault-b2.config` に分離し、Justfile 内の全コマンドで `--config-file=` を明示指定する。

## Consequences

- 良い面: 複数の kopia リポジトリを安全に併用できる
- 悪い面: 全コマンドに `--config-file` オプションが必要。Justfile でラップしているため実害は少ない
