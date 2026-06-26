# pkspec — Pkl で書く、言語横断テストランナー兼 spec contract

## tl;dr

- `Test.pkl` (Pkl の typed schema) でテストを書いて、`pkspec exec` で走らせる。 shell / HTTP / browser / SQL / playwright を 1 つの DSL で扱う
- `playwright test` の retry / `--shard=K/N` / `--rerun-failed` を、playwright だけでなく **すべての test kind に一般化**
- BDD 風の `Spec.pkl` (Scenario / Goal / Milestone / Decision) が `Test.pkl` の上に乗る。 `pkspec check --strict` が CI gate
- 既存ランナー (vitest / playwright / node:test / go test / moon test) は Pkl の **adapter DSL** で composition。Go 側に runner ごとの実装を抱え込まない
- ソースコードに `// pkspec:spec=<id>` marker を書くだけで、 「この実装はあの spec を満たす」を `pkspec lint --scan` が拾う
- `pkspec migrate` で v0.1.x → v0.2.0 の schema 変更を text-transform で吸収。 idempotent な `--check` モードを CI に挿せる
- MoonBit-native 実装 (0.4.x)。 `curl -fsSL https://raw.githubusercontent.com/mizchi/pkspec/main/install.sh | sh` / `nix profile install github:mizchi/pkspec` / GitHub Action は `uses: mizchi/pkspec@v0`

## なぜ書いてるか

テストは「shell スクリプトの集合」か「YAML の集合」になりがちで、 ランナーごとに retry や sharding を自前で実装している。playwright は `--retries` / `--shard=K/N` / `--rerun-failed` を built-in に持っているけど、 これは playwright 1 個の話。 同じ機能を vitest や go test や HTTP テストに横展開するときに、 また書く。

加えて「spec と test の対応」がドキュメントで管理されていて、 リネーム時に追従漏れる。 spec の id を rename したら test 側 specRef も更新する、 を仕組みで強制したい。

pkspec は両方を Pkl の型で解く:

- Test は **値** なので、 `cmd` と `steps` を両方持つ Test は author 時点で reject される。 ランナーが起動する前に判定される
- retry / sharding / timing は **runner 層** に置いて、 kind を問わず効く
- Spec → Test の link は `Scenario.id` と `Test.specRef` のクロス参照、 source marker `pkspec:spec=<id>` で実装側も link する

## 動かしてみる

```sh
curl -fsSL https://raw.githubusercontent.com/mizchi/pkspec/main/install.sh | sh
# pkl CLI も必要 (https://pkl-lang.org/main/current/pkl-cli/)

mkdir my-tests && cd my-tests
pkspec init                          # ./pkspec/{Test,Spec,Adapter,QuickCheck}.pkl + adapters/*.pkl を展開
# Test.pkl と Spec.pkl は自分で書く (init は schema だけ置く)
pkspec exec -f Test.pkl
```

`pkspec init` は schema 一式を `./pkspec/` 配下に展開するだけで、 `Test.pkl` / `Spec.pkl` 本体は自分で書く前提。 spec 側は `pkspec spec --template module` で雛形が出る (`amends` の `PATH/TO/` placeholder は init 後のパスに手で差し替える)。 最初の Test.pkl はこんな形:

```pkl
amends "./pkspec/Test.pkl"

tests {
  new {
    name = "login_smoke"
    specRef { "LOGIN-001" }
    steps {
      new {
        http = new HttpRequest {
          url = "http://localhost:3000/login"
          method = "POST"
          body = "{\"user\":\"alice\"}"
        }
        expectStatus = 200
      }
      new {
        name = "judge_message"
        http = new HttpRequest { url = "http://localhost:3000/login/welcome" }
        expectAi = new AiAssertion {
          prompt = "the response acknowledges the user in English"
          cmd = "claude --no-stream"
          snapshotName = "login-welcome"
        }
      }
    }
  }
}
```

`pkspec exec -f Test.pkl` でテストが走り、 `.pkspec/timings.jsonl` に履歴が append される。 そのまま:

```sh
pkspec exec -f Test.pkl --shard=2/4         # 4-way 履歴ベースの分割
pkspec exec -f Test.pkl --rerun-failed      # 前回失敗したテストだけ
pkspec timings -f Test.pkl --shard=2/4      # shard 内訳の preview (実行しない)
```

## 何で嬉しいのか

### 1. retry / shard / rerun-failed が kind 不問

| feature | flag / schema |
|---|---|
| per-attempt retry | `Test.retries`, `Test.flakyAcceptable` |
| cross-run shard split | `pkspec exec --shard=K/N` (LPT bin-packing) |
| rerun last fail set | `pkspec exec --rerun-failed` |
| global wall-clock cap | `pkspec exec --total-timeout=5m` |
| per-test wall-clock cap | `Test.timeoutSec` |
| polling / eventually | `Step.eventually = new Eventually { intervalMs; timeoutSec }` |

shard は append-only `.pkspec/timings.jsonl` の median (最新 5 run) を使って LPT bin-packing する。 同じ input なら同じ machine 配置に決まるので、 CI の matrix 配分が deterministic。

### 2. 既存 runner を adapter として取り込む

```pkl
amends "./pkspec/Adapter.pkl"

import "./pkspec/adapters/Vitest.pkl" as Vitest

local class WebVitest extends Vitest.Vitest {
  configPath = "packages/web/vitest.config.ts"
  include = new { "src/**/*.test.ts" }
}

suites {
  new {
    name = "web-unit"
    adapter = new WebVitest {}
    overlays {
      ["src/parser.test.ts::empty input"] = new CaseOverlay {
        specRef { "parser.empty" }
      }
    }
  }
}
```

`pkspec adapter -f Adapter.pkl` で起動。 vitest / playwright / node:test / go test / moon test が built-in adapter。 generic 'protocol' (`discover` JSON → manifest → JSONL events) で動くので、 native runner は変えずに pkspec が指揮を取る。 新 runner を組み込むときは Go の registry に手を入れず、 Pkl の adapter subclass を 1 つ書けば良い。

### 3. Spec.pkl は test に didn't write な層を埋める

```pkl
goals {
  new Goal {
    id = "GOAL-SECURE-AUTH"
    name = "users can authenticate securely"
    priority = 90
    reviewStatus = "approved"
  }
}

scenarios {
  new {
    id = "AUTH-001"
    name = "valid credentials"
    severity = "critical"
    reviewStatus = "approved"
    contributes { "GOAL-SECURE-AUTH" }
    dependsOn { "SESSION-001" }
    decisions {
      new Decision {
        date = "2026-03-01"
        author = "mizchi"
        summary = "lock the spec to cookie-based auth"
      }
    }
    tags { "spec" }
  }
}
```

```sh
pkspec check --strict SPEC.pkl     # CI gate: 未実装 / draft 漏れがあると exit 1
pkspec spec --next SPEC.pkl        # 未実装 Scenario を Goal priority で並べる
pkspec spec --orphans SPEC.pkl     # specRef 無しの active Test
pkspec spec --coverage SPEC.pkl    # severity / reviewStatus 別の coverage
pkspec graph --scan SPEC.pkl       # graphviz dot (source marker backlinks 付き)
pkspec docs --audience pm SPEC.pkl # audience tag で projection
```

`pkspec next` は「次に手を付けるべき spec」を出してくれるので、 backlog から Issue に起こす作業がほぼ機械化される。

### 4. source marker でコードからも spec に link

```go
// internal/auth/login.go
//
// pkspec:spec=AUTH-001
func ValidateCredentials(...) { ... }
```

`pkspec lint --scan` がコード中の `pkspec:spec=<id>` を拾って、 「この id は Spec.pkl に居る?」「id を rename した跡で dead link になってない?」 をチェックする。 ドキュメント側ではなく **コード側に書ける** のがミソ。 リファクタの動線に乗る。

### 5. v0.2.0 schema 変更を migrate で吸収

```sh
pkspec migrate --dry-run path/to/Spec.pkl   # diff を preview
pkspec migrate path/to/Spec.pkl              # 書き換える
pkspec migrate --check path/to/Spec.pkl      # CI 用: 差分があれば exit 1
```

v0.1.x で `implementedBy = "code"` + `implementedAt = "X"` だったのを `implementations { new Implementation { kind = "code"; at = "X" } }` に rename した時、 手で書き換えずに済む。 idempotent なので CI に `--check` を挿しておけば一括移行漏れも検出できる。

### 6. pkfire との spec ↔ task リンク

main branch (次の patch release で入る) の `new TaskImpl { at = "Taskfile.pkl#release" }` で、 pkfire の task を Scenario の実装先に名指せる。 同じリリースで `Implementation` が abstract 化され、 `TestImpl` / `CodeImpl` / `DocImpl` / `TaskImpl` の 4 つの typed subclass に分かれた。 v0.1.x → v0.2.x の移行と同様、 `pkspec migrate` が flat 形式 → typed subclass の rewrite を担当する。 試すなら `curl -fsSL https://raw.githubusercontent.com/mizchi/pkspec/main/install.sh | sh` で最新リリースの binary を入れる。

```pkl
scenarios {
  new {
    id = "release-pipeline"
    name = "release tag is pushed by the runner"
    reviewStatus = "approved"
    implementations {
      new TaskImpl { at = "Taskfile.pkl#release" }
    }
  }
}
```

`pkspec check --strict` 時:
- `Taskfile.pkl` の存在を on-disk 確認
- `pkf` が PATH にあれば `pkf list --json -f Taskfile.pkl` を呼んで、 `release` task が宣言されているかまで cross-check

build / release / migration のような「コードに 1 ファイルとして居場所が無い」実装も spec から指せるようになった。 逆向きには pkfire main の `Task.specRef` で task → spec を名乗れる (こちらも次の pkfire 0.11.0 リリースに入る予定)。 `examples/pkfire-task-link/` を参照。

## 設計上の限界

- **pkl 必須**。 `pkspec` は `pkl-go` 経由で `pkl` CLI を呼ぶので、 `pkl` が無い環境 (一部の minimal CI image) では `pkspec doctor` が FAIL する。 Nix 経由 install ならまとめて入る
- **adapter は 100% カバーしない**。 vitest / playwright / node:test / go test / moon test は built-in だけど、 ecosystem 全制覇は明示的に target に置いていない。 必要な ecosystem は Pkl の adapter DSL で自分で書く前提 (Pkl 数十行で済む)
- **expectAi は judge command 次第**。 LLM 呼び出しは外部 cmd に委譲するので、 reproducibility はその cmd 側の deterministic 性に乗る。 verdict は `sha256(prompt + body)` で cache されるので、 同じ input なら再呼び出ししない
- **言語非依存 = 言語固有のテストフレームワーク機構には深入りしない**。 fixtures / parameterize / pytest みたいな language-level の便利機構は、 adapter 越しに native runner に投げて中で解決させる

## 次のリリース

- `Implementation.kind = "task"` の cross-check (pkfire との連携) は main に入っており、 次の patch リリースで公開予定。 ノートは [`examples/pkfire-task-link/`](https://github.com/mizchi/pkspec/tree/main/examples/pkfire-task-link) にある
- 直近の dogfood サイクル (0.1.13 → 0.2.1) では source marker → graph backlinks、 doctor の openQuestions 連動、 domain-prefix の lint オプトイン化を入れた

## さわってみる

```sh
curl -fsSL https://raw.githubusercontent.com/mizchi/pkspec/main/install.sh | sh
mkdir my-tests && cd my-tests
pkspec init                                # pkspec/ 配下に schema を展開
# Test.pkl と Spec.pkl を自分で書く
#   - Spec.pkl の雛形は `pkspec spec --template module` で出る
#     (出力中の `PATH/TO/pkspec/pkl/` を `pkspec/` に置換する)
pkspec exec -f Test.pkl
pkspec check --strict Spec.pkl
```

Repo: https://github.com/mizchi/pkspec / Quick start: [docs/quick-start-ja.md](./quick-start-ja.md)
