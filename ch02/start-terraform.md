# Start Terraform.

## Terraform のインストール

```
# macOS
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

```
# Windows
choco install terraform
```
```
# プロファイルを作成
aws configure --profile terraform-learning
```

```
# 環境変数の設定
# macOS
export AWS_ACCESS_KEY_ID=(自分のID)
export AWX_SECRET_ACCESS_KEY=(シークレットキー)
```
```
# 環境変数の設定
# Windows
set AWS_ACCESS_KEY_ID=(自分のID)
set AWX_SECRET_ACCESS_KEY=(シークレットキー)
```

