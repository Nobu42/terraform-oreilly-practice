# 第3章 State管理と構成の分離

[リポジトリのトップ](../README.md) | [第2章へ](../ch02/README.md)

記録日: 2026-09-16

> S3・MySQL・Webクラスタを別の構成として管理し、それぞれのStateをS3へ保存しました。DBの出力をWeb側から読み取り、ブラウザに表示するところまで確認しました。

## 目次

- [この章の要点](#この章の要点)
- [Stateの保存とロック](#stateの保存とロック)
- [S3バックエンドへの移行](#s3バックエンドへの移行)
- [フォルダとStateの分離](#フォルダとstateの分離)
- [MySQLの作成](#mysqlの作成)
- [変数の入力](#変数の入力)
- [Remote Stateとテンプレート](#remote-stateとテンプレート)
- [ミスと対処](#ミスと対処)
- [後片付け](#後片付け)
- [確認できた結果](#確認できた結果)

## この章の要点

**単にフォルダを分けるのではなく、管理するリソースの単位ごとにコードとStateを分離すること**を学びました。

| 構成 | 役割 | 作成順 |
| --- | --- | --- |
| S3とDynamoDB | Stateの保存先とロック用の共通基盤 | 1 |
| MySQL | ステージング環境のデータベース | 2 |
| Webクラスタ | ステージング環境のWebサーバ。DBの出力値を参照 | 3 |

各フォルダで個別に `init`・`plan`・`apply` を行います。親の `ch03` で実行しても、配下の全フォルダがまとめて実行されるわけではありません。
今回のS3はアプリケーション用のデータ置き場ではなく、TerraformのState保存用です。

## Stateの保存とロック

### ファイルの違い

| ファイル・設定 | 役割 |
| --- | --- |
| `terraform.tfstate` | 管理対象のリソース情報と出力値などを記録する |
| `.terraform/` | Provider、バックエンドの初期化情報などを保持する |
| `.terraform.lock.hcl` | Providerの選択バージョンと検証用情報を記録する |
| State lock | 同じStateに対する同時操作を調整する仕組み |

**`.terraform.lock.hcl` は、AWSリソースのStateでも、同時実行を防ぐロックそのものでもありません。**
また、`.terraform/terraform.tfstate` はバックエンド設定のメタデータであり、S3上のリソースStateそのものではありません。

### 保存先として用意したもの

- State保存用のS3バケット。
- S3のバージョニング。誤操作からの復旧に備えるために有効化した。
- AES256のサーバー側暗号化と、4項目すべてのパブリックアクセスブロック。
- DynamoDBのロック用テーブル。課金モードは `PAY_PER_REQUEST`、パーティションキーは文字列型の `LockID`。
- S3の `lifecycle { prevent_destroy = true }`。

S3のバージョニングは推奨される保護策で、バックエンド利用そのものの必須条件とは区別します。

### 削除関連の設定

| 設定 | 意味 |
| --- | --- |
| `force_destroy = true` | S3の削除時、内容があっても削除を許可する。設定しただけで即削除されるわけではない |
| `lifecycle { prevent_destroy = true }` | そのリソースを削除・置き換えするTerraformの計画を拒否する |

この2つは逆の目的の設定です。`prevent_destroy` はAWSコンソールやCLIからの削除を防ぐものではなく、リソース定義自体をコードから取り除いた場合にも保護は残りません。

今回、S3を管理するフォルダで `destroy` を実行すると、`prevent_destroy` によって計画段階で停止しました。その実行では削除は行われていません。

### DynamoDBの非推奨警告

`dynamodb_table` の警告はエラーではなく、実際にStateのロック取得・解除は成功しました。
この学習では書籍に合わせてDynamoDB方式を使っています。現在はS3の `use_lockfile` が用意されているため、新しく設計する場合は対応バージョンとIAM権限も含めて検討します。今回は方式の切り替え自体は実施していません。

参考: [S3バックエンド](https://developer.hashicorp.com/terraform/language/backend/s3)、[prevent_destroy](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#prevent_destroy)、[S3バケットの削除設定](https://github.com/hashicorp/terraform-provider-aws/blob/v4.67.0/website/docs/r/s3_bucket.html.markdown)

## S3バックエンドへの移行

まずローカルStateでS3・DynamoDBを作り、その後S3バックエンドを設定して既存Stateを移しました。
バックエンドが使うS3バケットは、バックエンド初期化より先に存在している必要があります。

次は設定の抜粋です。`<STATE_BUCKET_NAME>` と `<LOCK_TABLE_NAME>` は、自分が作成した名前に置き換えます。

```hcl
terraform {
  backend "s3" {
    bucket         = "<STATE_BUCKET_NAME>"
    key            = "global/s3/terraform.tfstate"
    region         = "us-east-2"
    profile        = "terraform-learning"
    dynamodb_table = "<LOCK_TABLE_NAME>"
    encrypt        = true
  }
}
```

- `backend` の中では `var.bucket_name` のような入力変数は使えない。
- AWS Providerの `profile` と、バックエンドの認証設定は別。今回はこちらにもプロファイルを明示した。
- バックエンド追加後は `validate` の成功だけでは足りず、`init` が必要。
- 実際の初回移行では `terraform init` の「既存Stateをコピーするか」という確認に `yes` と答えた。
- 移行後に `plan` と `apply` を行い、`No changes`、`0 added, 0 changed, 0 destroyed` を確認した。

既存の保存先からの移行には `terraform init -migrate-state` を使う場面があります。`-reconfigure` は既存Stateを移行する指定ではないため、同じものとして扱わないことが重要です。

参考: [バックエンドの設定](https://developer.hashicorp.com/terraform/language/backend)、[terraform init](https://developer.hashicorp.com/terraform/cli/commands/init)

### 部分設定について

書籍の `backend.hcl` は、バケット・リージョンなどの共通設定を外へ出す方法です。
`.hcl` という名前だけで自動的に読み込まれるわけではなく、`terraform init -backend-config=backend.hcl` のように指定します。
今回の構成では設定を `main.tf` に直接書いており、外出しは必須ではありません。部分設定は説明を確認した内容で、実行済みとは扱いません。

## フォルダとStateの分離

### 構成

```text
ch03/
|-- global/
|   `-- s3/
|       |-- main.tf
|       |-- variable.tf
|       `-- outputs.tf
`-- stage/
    |-- data-stores/
    |   `-- mysql/
    |       |-- main.tf
    |       |-- variables.tf
    |       `-- outputs.tf
    `-- services/
        `-- webserver-cluster/
            |-- main.tf
            |-- variables.tf
            |-- outputs.tf
            `-- user-data.sh
```

`.terraform/` と `.terraform.lock.hcl` も、初期化した構成ごとに存在します。

| 対象 | コード | S3内のStateのkey |
| --- | --- | --- |
| 共通基盤 | [global/s3](global/s3/main.tf) | `global/s3/terraform.tfstate` |
| DB | [stage/data-stores/mysql](stage/data-stores/mysql/main.tf) | `stage/data-stores/mysql/terraform.tfstate` |
| Web | [stage/services/webserver-cluster](stage/services/webserver-cluster/main.tf) | `stage/services/webserver-cluster/terraform.tfstate` |

同じS3バケットでも、各構成の `key` を変えます。無関係な構成で同じStateを共有すると、別の構成のリソースまで削除対象にしてしまう危険があります。

`stage` はステージング環境、`state` はTerraformの管理情報です。名前が似ていますが別の単語です。
ローカルの `global/s3` は「globalの中のs3」というディレクトリ構造で、`mkdir -p global/s3` で作成できます。

### S3のkeyの意味

`key` は、バケット内のオブジェクトを識別する名前です。OSの「ファイル名まで含めたパス」に近い表現です。
今回の通常のS3バケットでは実際のディレクトリ階層があるわけではなく、`/` を含むキーをコンソールがフォルダのように表示します。

参考: [S3のオブジェクトキー](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-keys.html)

### フォルダ移動で注意したこと

- S3用のTerraformファイルを移すことは、AWSのバケットそのものを移動・再作成することではない。整理だけなら `destroy` は不要。
- `cp -p` だけでは `.terraform` のようなディレクトリをコピーできず、今回は `cp -pr` に修正した。
- `.terraform` のコピーは既存リソースのStateの引き継ぎを保証しない。ローカルStateが残っている構成なら、その引き継ぎも別途確認する。
- `.terraform` をコピーしても、バックエンドを追加・変更したら再初期化が必要。
- 第2章のコードをWebフォルダへコピーし、Web専用のS3バックエンドを追加した。
- 実行先のディレクトリは毎回 `pwd` で確認する。

### Workspaceとの違い

CLI Workspaceは同じコード・作業ディレクトリの中でStateを切り替える仕組みです。新しいWorkspaceは、既存Workspaceの管理対象を自分のStateとして引き継ぎません。
今回はフォルダ分離を実施しました。書籍の `example1`・`example2` のWorkspace演習については、説明を確認したものの、作成完了ログは確認していません。

フォルダやStateを分けるだけではAWSの権限までは分離されません。今回の個人検証は同じアカウント・プロファイルを利用しており、本番とステージングをアカウント・認証・権限まで分ける設計とは区別します。

参考: [CLI Workspaces](https://developer.hashicorp.com/terraform/cli/workspaces)

## MySQLの作成

RDSにMySQLを1つ作成しました。[main.tf](stage/data-stores/mysql/main.tf) の主要部分です。

```hcl
resource "aws_db_instance" "example" {
  identifier_prefix   = "terraform-up-and-running"
  engine              = "mysql"
  allocated_storage   = 20
  instance_class      = "db.t3.micro"
  skip_final_snapshot = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password
}
```

| 項目 | 学習時の修正・確認 |
| --- | --- |
| DBクラス | 書籍由来の `db.t2.micro` から `db.t3.micro` へ変更。RDSのT2は新規作成不可 |
| 容量 | 10 GiBから20 GiBへ変更。今回のデフォルトのgp2でMySQLの最小容量を満たす |
| ユーザー名の引数 | `user_name` ではなく `username` |
| DB名 | `db_name` はDB内部の名前。RDSのインスタンス識別子やS3のkeyとは別 |
| 出力 | [outputs.tf](stage/data-stores/mysql/outputs.tf) で `address` と `port` を公開 |
| 削除 | `skip_final_snapshot = true` のため、削除時に最終スナップショットを残さない |

第2章のEC2の `t2.micro` と、RDSの `db.t2.micro` は別のサービスの設定です。RDSの変更を、そのままEC2の変更理由として扱いません。

作成結果は `Resources: 1 added, 0 changed, 0 destroyed`。出力されたポートは `3306` でした。
実際のDBエンドポイントは、この公開用記録では省略しています。

参考: [RDSのDBクラス](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Concepts.DBInstanceClass.Types.html)、[ストレージ容量の条件](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_CreateDBInstance.html)、[Provider v4.67.0のDB仕様](https://github.com/hashicorp/terraform-provider-aws/blob/v4.67.0/website/docs/r/db_instance.html.markdown)

## 変数の入力

### 入力欄は実行確認ではない

`var.xxx` に続く `Enter a value:` は、その変数の値を入力する欄です。
すべてに `yes` と答えるわけではありません。

| 入力欄 | 入れるもの |
| --- | --- |
| `var.db_name` | DB名。学習では `example` を例として案内 |
| `var.db_username` | DBのログインユーザー名 |
| `var.db_password` | DBのパスワード。公開しない |
| `var.db_remote_state_bucket` | DBのStateが保存されたS3バケット名 |
| `var.db_remote_state_key` | `stage/data-stores/mysql/terraform.tfstate` |
| `apply`・`destroy` の最終確認 | 計画が意図どおりなら `yes` |

実際に `db_name` に `yes` と入力すると、`yes` というDB名の計画になりました。
バケット名とキーの入力で `yes` と答えたときは、バケット `yes` のオブジェクト `yes` を読もうとして403エラーになりました。そこで必要だったのは権限の拡張ではなく、入力値の修正です。

### コマンド引数で渡す

Web側の実行例です。バケット名は置き換えてください。

```bash
terraform plan \
  -var='db_remote_state_bucket=<STATE_BUCKET_NAME>' \
  -var='db_remote_state_key=stage/data-stores/mysql/terraform.tfstate'
```

`-var` はその実行に対する指定です。次の `terraform apply` でも同じ値が必要なので、同じ `-var` を付けるか、入力欄で正しい値を渡します。

### 環境変数で渡す

`TF_VAR_` に変数名を続けると、Terraformの入力値として渡せます。
今回のBashで、DB認証情報をコマンド履歴に直書きしない入力例:

```bash
read -r -p "DB username: " TF_VAR_db_username
read -r -s -p "DB password: " TF_VAR_db_password
printf '\n'
export TF_VAR_db_username TF_VAR_db_password
```

パスワードは画面に表示されません。この設定はそのシェルから実行するTerraformに引き継がれ、別のターミナルへ自動で設定されるものではありません。
作成済みのDBを同じ設定で扱う場合は、作成時の値を使います。

`sensitive = true` は表示の抑制です。コードに直書きした秘密を消す仕組みではなく、今回の `password` 引数はStateにも保存されます。
一度コードを連結した `.txt` にも秘密が残るため、元の `.tf` を修正しただけで安心しないことが重要です。
また、Remote Stateの読み取り権限を持つ人はState全体へアクセスできるため、出力値だけを見せる安全な境界とは考えません。

参考: [TF_VAR](https://developer.hashicorp.com/terraform/cli/config/environment-variables#tf_var_name)、[機密情報の扱い](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)

## Remote Stateとテンプレート

### 自分のStateと参照するState

Web側には、S3を指定する設定が2か所ありますが、目的が違います。

| 設定 | 用途 | key |
| --- | --- | --- |
| `terraform { backend "s3" { ... } }` | Web自身のStateの保存 | `stage/services/webserver-cluster/terraform.tfstate` |
| `data "terraform_remote_state" "db"` | DB側のStateの出力値を読む | `stage/data-stores/mysql/terraform.tfstate` |

```hcl
data "terraform_remote_state" "db" {
  backend = "s3"

  config = {
    bucket  = var.db_remote_state_bucket
    key     = var.db_remote_state_key
    region  = "us-east-2"
    profile = "terraform-learning"
  }
}
```

DB側の [outputs.tf](stage/data-stores/mysql/outputs.tf) が公開した値を、次のように参照します。

```hcl
data.terraform_remote_state.db.outputs.address
data.terraform_remote_state.db.outputs.port
```

DBの `plan` だけでは、今回必要な出力を持つStateは用意できません。先にDB側の `apply` を完了し、そのStateをWeb側が読みます。
別フォルダのDBを、Web側の `apply` が自動で作成してくれるわけではありません。

参考: [terraform_remote_state](https://developer.hashicorp.com/terraform/language/state/remote-state-data)

### User Dataに埋め込む

Web側の [main.tf](stage/services/webserver-cluster/main.tf) から、[user-data.sh](stage/services/webserver-cluster/user-data.sh) に3つの値を渡します。

```hcl
user_data = base64encode(templatefile("user-data.sh", {
  server_port = var.server_port
  db_address  = data.terraform_remote_state.db.outputs.address
  db_port     = data.terraform_remote_state.db.outputs.port
}))
```

```bash
#!/bin/bash

cat > index.html <<EOF
<h1>Hello, World</h1>
<p>DB address: ${db_address}</p>
<p>DB port: ${db_port}</p>
EOF

nohup busybox httpd -f -p ${server_port} &
```

1. TerraformがS3上のDBのStateから出力値を読む。
2. `templatefile` が `${db_address}` などを実際の値に置き換える。
3. `base64encode` でLaunch Templateに渡す形式へ変換する。暗号化ではない。
4. 起動したEC2がスクリプトを実行し、HTMLを作ってHTTPサーバを起動する。
5. ブラウザからALB経由で表示を確認する。

`${...}` は今回のテンプレート変数の展開に使います。`$(...)` と書くと、シェルのコマンド置換になってしまいます。
テンプレートへ渡すキー名と、テンプレート内の名前は完全に一致させます。

**このWebページはDBの接続先を表示するだけで、MySQLへの接続やSQL実行はしていません。**
また、Webページは起動時に生成した内容です。DBのStateを更新しただけで、稼働中のページが自動的に書き換わる仕組みではありません。

参考: [templatefile](https://developer.hashicorp.com/terraform/language/functions/templatefile)、[base64encode](https://developer.hashicorp.com/terraform/language/functions/base64encode)

## ミスと対処

### 設定・初期化・State

| 症状 | 原因 | 対処 |
| --- | --- | --- |
| `Missing required provider` | 新しい作業ディレクトリでProviderを利用できなかった | そのフォルダで `terraform init` |
| `Backend initialization required` | S3バックエンドを追加したが初期化していなかった | `validate` とは別に `init` を実施 |
| backend内で `var.bucket_name` を使おうとした | バックエンド設定は入力変数を参照できない | 名前を直接指定。部分設定は別の方法として理解 |
| `Instance cannot be destroyed` | S3の `prevent_destroy` が有効 | フォルダ整理には削除が不要と確認し、保護を維持 |
| フォルダのコピーに失敗 | `cp -p` に再帰コピー指定がなかった | `.terraform` には `cp -pr` を使用 |
| DBの参照で403 | バケットとkeyの両方へ `yes` を入力していた | 正しいState保存先を入力 |
| `Unable to find remote state` | 指定先にDBのStateが見つからなかった | MySQL側の `apply` 完了後にWebの計画を再実行 |
| MySQLにS3用のoutputをコピー | 別フォルダの未定義リソースを参照していた | DB側は `address` と `port` の出力だけに整理 |
| `plan` の途中に作成件数が表示された | 後段でエラーが発生した部分的な計画だった | 件数だけで成功と判断せず、最後のエラーまで確認 |

### タイポ・式・変数

| 間違い | 正しい内容 |
| --- | --- |
| `resuorce` | `resource` |
| `verioning_configuration` | `versioning_configuration` |
| `blling_mode` | `billing_mode` |
| `bucket = "var.bucket_name"` | `bucket = var.bucket_name`。引用符付きは文字どおりの文字列 |
| `dynamo_table` | `dynamodb_table` |
| `terraform-leaning` | `terraform-learning` |
| `buckend "s3"` | `backend "s3"` |
| `bucketend = "s3"` | `backend = "s3"` |
| RDSの `user_name` | `username` |
| `user-datta.sh` | 実在するファイル名の `user-data.sh` |
| `db_pote` | テンプレートと同じ `db_port` |
| 古いUser Dataをコメント化した後の単独の `)` | 不要な閉じ括弧も削除・コメント化する |
| `$(db_address)` など | `${db_address}`、`${db_port}`、`${server_port}` |
| Launch Templateへ通常のテンプレート文字列を渡す | `base64encode(templatefile(...))` |
| `data.terraform_remote_state.db` の定義がない | `data "terraform_remote_state" "db"` を追加 |
| `db_name` に `yes` を入力 | 承認ではなく、自分で決めたDB名を入力 |
| パスワードを `default` へ直書き | 初期値を取り除き、対話入力・環境変数などで渡す |

修正後は `fmt` と `validate` を行い、その後に `plan` で確認しました。
`validate` が成功しても、Stateの読み取りやAWS側の作成条件まで確認済みとは限りません。

## 後片付け

### 削除する順番

**Webクラスタ -> MySQL** の順で削除する方針にしました。DB側のStateが必要なWeb側を先に片付けます。
S3とロック用DynamoDBは共通基盤として残す方針です。

> 以下は復習用の手順です。実際の削除では、対象のState・ワークスペースと削除計画を確認してください。DBのデータが必要なら、そのまま削除しないでください。

Web側のディレクトリで、まず削除計画を確認します。`<STATE_BUCKET_NAME>` は置き換えます。

```bash
terraform plan -destroy \
  -var='db_remote_state_bucket=<STATE_BUCKET_NAME>' \
  -var='db_remote_state_key=stage/data-stores/mysql/terraform.tfstate'
```

意図した対象だけであれば、次を実行します。実行前にも表示される計画を確認します。

```bash
terraform destroy \
  -var='db_remote_state_bucket=<STATE_BUCKET_NAME>' \
  -var='db_remote_state_key=stage/data-stores/mysql/terraform.tfstate'
```

Web側の完了後、MySQLのディレクトリで `terraform destroy` を実行します。
削除時も入力変数を聞かれる場合があります。作成時と同じ値を渡し、最終確認のときだけ `yes` と答えます。
今回のDBは最終スナップショットを残さない設定なので、データを残したい場合は削除前に対応が必要です。

### S3は先に削除しない

今回のS3は、他の構成に加えてS3自身を管理するStateも保存しています。
`prevent_destroy` を外すだけで削除に進まず、共通基盤まで完全撤去する場合は、すべての利用構成を確認し、必要なStateをローカルなど別のバックエンドへ移行してから片付けます。
バージョニング済みオブジェクトの削除は、復旧用の過去Stateも失う操作です。

`destroy` 後もStateやS3の過去バージョンは残り得ます。リソースの削除と、State履歴の消去を同一視しません。
また、完了判定は `Destroy complete!` に加え、管理対象の確認やAWS側の残存リソースの確認で行います。この資料の作成時にAWSへの照会は行っていません。

参考: [terraform destroy](https://developer.hashicorp.com/terraform/cli/commands/destroy)

## 確認できた結果

| 項目 | 確認状況 |
| --- | --- |
| S3バックエンドへの既存State移行 | コピー確認に `yes` と回答し、初期化成功 |
| S3管理構成の整合性 | `No changes` と0件変更の `apply` を確認 |
| DynamoDBによるロック | ロック取得・解除を確認。非推奨警告は残る |
| MySQLの作成 | 1リソース追加完了、`address` と `port = 3306` を確認 |
| Webの構成検証 | タイポ修正後に `validate` 成功 |
| DB情報を使うWebページ | ブラウザで `Hello, World`、DB address、DB portを確認 |
| WebからMySQLへの実接続 | 今回のコードでは行っていない |
| Web・DBの削除 | 手順を確認し、MySQLの `destroy` の入力段階まで共有された。両構成の削除完了ログは未確認 |
| S3・DynamoDB | 残す方針。記録作成時点のAWS実環境は照会していない |

**学習の完了と、課金対象リソースの削除完了は別に確認すること**が、最後の注意点です。

[トップに戻る](#第3章-state管理と構成の分離) | [第2章へ](../ch02/README.md) | [リポジトリのトップ](../README.md)
