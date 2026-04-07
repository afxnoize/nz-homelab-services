# Architecture Decision Records

設計判断の記録。一度acceptedになった判断をagentが再議論するのを防ぐ。

## ファイル命名規則

```
{3桁連番}-{slug}.md
例: 001-monorepo-structure.md
```

- 連番は欠番を作らない（supersededでも残す）
- slugはケバブケースで、判断内容を端的に表す

## Status Values

| Status | 意味 |
|---|---|
| `proposed` | 提案中。議論の余地あり |
| `accepted` | 採用済み。従うこと |
| `deferred` | 保留。条件が揃ったら再検討 |
| `superseded` | 別のADRに置き換え済み |

## Template

各ADRファイルは以下の形式で作成する。

```markdown
# ADR-{番号}: {タイトル}

- **Status**: proposed | accepted | deferred | superseded
- **Date**: YYYY-MM-DD
- **Superseded by**: ADR-{番号} (該当する場合)

## Context

なぜこの判断が必要か

## Decision

何を決めたか

## Consequences

この判断の結果、何が変わるか（良い面・悪い面）
```
