# ADR-001: モノレポ構成

- **Status**: accepted
- **Date**: 2025-04-01

## Context

複数のホームラボサービス（バックアップ、パスワード管理など）を管理する必要がある。サービスごとに別リポジトリにすると、共通ツールチェイン（Nix Flakes, SOPS, just）の重複管理が発生する。

## Decision

全サービスを `services/<name>/` に配置するモノレポ構成とする。各サービスは Justfile + secrets.yaml + README.md を持ち、ルートの Justfile が `mod` 機能でサービスを束ねる。

## Consequences

- 良い面: ツールチェインの一元管理、`flake.nix` 一つで全環境を固定できる
- 悪い面: サービス間の意図しない結合が生じうる。サービス境界を意識して独立性を保つ必要がある
