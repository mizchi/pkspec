# pkspec クイックスタート

pkspec は、Pkl で書く実験的な spec / test runner です。

役割は大きく 2 つあります。

- Pkl で型付きに定義したテストを実行する
- プロダクト上の意図や仕様を、実行可能なテストにつなげて管理する

shell script、HTTP check、browser flow、SQL check、既存の native
runner、複数言語のテストが混在しているリポジトリで、それらを 1 つの
レビュー面にまとめたいときに使います。

## 作者の意図

pkspec は、いくつかの明確な意図を持って設計しています。

- **Pkl による堅牢なテストランナー**: テスト定義は schema で検査でき、
  合成しやすく、CI が走り始める前に設定ミスを見つけられるべきです。
- **言語中立性**: spec と test の contract は、特定の ecosystem の上ではなく、
  その外側に置きます。Shell、HTTP、browser、SQL、Go、Node、Moon などを、
  どれか 1 つの言語中心にせず扱えるようにします。
- **構造的なテストフローと実装テストの対応付け**: 高レベルの Goal / Scenario と、
  それを検証する `Test.pkl`、native runner、code、doc artifact を結び付けます。
- **仕様駆動開発のためのドキュメント**: spec は machine input だけでなく、
  review document として読めるべきです。同じ graph から CI gate、product review、
  読者別 docs、実装計画を支えます。

## pkspec とは何か

pkspec では、テストをその場限りの script や YAML ではなく、型付きの
データとして扱います。`Test.pkl` には shell、HTTP、Playwright、SQL、
adapter 経由の native runner などを記述できます。Go 製の runner がそれを
実行し、CI に信頼できる exit code を返します。

さらに上位層として `Spec.pkl` があります。

- `Goal`: ユーザーやプロダクトにとっての価値
- `Scenario`: 成り立ってほしい振る舞い
- `Test`: その振る舞いを検証する実行可能なチェック

これにより、リポジトリに対して次のような問いに答えられます。

- approved な仕様のうち、まだ実装されていないものはどれか
- このプロダクト上の振る舞いを検証しているテストはどれか
- 次に実装すべき仕様はどれか
- どの Goal がどれくらい達成されているか
- どんな意思決定の履歴があるか

## インストール

Nix を使う場合:

```sh
nix run github:mizchi/pkspec/v0.1.13 -- version
```

Go を使う場合:

```sh
go install github.com/mizchi/pkspec/cmd/...@v0.1.13
pkspec version
```

プロジェクト内に schema を配置する場合:

```sh
pkspec init --dir pkspec
```

これにより `pkspec/Test.pkl`、`pkspec/Spec.pkl`、関連 schema が書き出されます。
リポジトリ内の Pkl module は、pkspec のソースチェックアウトに直接依存せずに
書けるようになります。

## 最初のテスト

`Test.pkl` を作ります。

```pkl
amends "./pkspec/Test.pkl"

tests {
  new {
    name = "hello"
    cmd = "echo hello"
    expectStdout = "hello\n"
  }
}
```

実行します。

```sh
pkspec exec -f Test.pkl
```

期待される出力:

```text
[pkspec] hello: passed
pkspec: 1 passed, 0 flaky, 0 pending, 0 failed, 0 errored, 0 skipped (of 1)
```

## 最初の Spec

starter spec を生成します。

```sh
mkdir -p specs
pkspec spec --template module > specs/upload.pkl
```

`specs/upload.pkl` 内の `amends` のパスを直してから、表示します。

```sh
pkspec spec specs/upload.pkl
```

実際のテストとつなぐ準備ができたら、安定した Scenario id を `specRef` に
追加します。

```pkl
tests {
  new {
    name = "upload_smoke"
    specRef { "example.replace-me" }
    cmd = "true"
  }
}
```

これで pkspec は spec graph を検査できます。

```sh
pkspec check --discover
pkspec lint --discover
pkspec goals --discover
pkspec next --discover
```

## よく使うコマンド

```sh
pkspec exec -f Test.pkl                  # テストを実行する
pkspec exec -f Test.pkl --rerun-failed   # 前回失敗したテストだけ実行する
pkspec exec -f Test.pkl --shard=1/4      # timing に基づく shard の一部を実行する
pkspec timings -f Test.pkl --shard=1/4   # shard 割り当てを実行せずに確認する

pkspec spec --discover                   # spec index を出力する
pkspec check --strict --discover         # approved spec の CI gate
pkspec lint --discover                   # 壊れた参照や authoring mistake を検出する
pkspec docs --audience pm --discover     # 読者別の docs を生成する
```

## 次に読むもの

- [Authoring guide](./notes/authoring-guide.md): Goal、Scenario、Test の書き方
- [Spec graph](./notes/spec-graph.md): graph field と review command のリファレンス
- [Runner design](./notes/runner-design.md): pkspec がテストを実行する仕組み
- [Adapters](./notes/adapters.md): Vitest、Playwright、node:test、Go test、Moon test など既存 runner の取り込み
- [Advanced Goals and Milestones](./advanced/goals-and-milestones.md): spec graph 導入後の planning 向けレポート
- [pkfire](https://github.com/mizchi/pkfire): cache 付き project task や
  build-style workflow を扱う sibling task runner。pkspec は typed test、
  spec link、review / CI reporting に集中します。
