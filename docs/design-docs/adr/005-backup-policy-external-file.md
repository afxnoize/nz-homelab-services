# ADR-005: バックアップポリシーの外部ファイル化

- **Status**: accepted
- **Date**: 2025-04-01

## Context

保持ポリシー（daily: 7, weekly: 4）やバックアップ対象パスを Justfile にハードコードすると、変更時にコマンドロジックとデータが混在する。

## Decision

保持ポリシーは `policy.yaml`、バックアップ対象パスは `sources.yaml`（gitignore）で管理する。`just backup connect` 時に yq で読み取って kopia に設定する。

## Consequences

- 良い面: データとロジックが分離。ポリシー変更が宣言的で差分が明確
- 悪い面: yq への依存が増える（Nix で解決済み）
