# Cloud Forge Catalog

Cloud Forge CLI 的模板商店仓库。包含应用索引（`index/apps.json`）、IaC 模板（CFN / ROS）及 JSON Schema。

## 目录结构

```
cloud-forge-catalog/
├── index/
│   └── apps.json              # CLI 拉取的全局索引（由 scripts 生成）
├── apps/
│   └── <app-id>/
│       ├── manifest.json      # 单应用元数据（编辑此文件）
│       └── templates/
│           ├── aws.yaml       # CloudFormation
│           └── aliyun.json    # ROS
├── schema/
│   └── app-v1.schema.json     # manifest 校验 Schema
└── scripts/
    └── build-index.sh         # 从 manifest 生成 index/apps.json
```

## CLI 对接

CLI 通过 HTTP 拉取索引，按需下载模板：

```yaml
# ~/.cloud-forge/config.yaml
store:
  url: https://raw.githubusercontent.com/CoreNovaLabs/cloud-forge-catalog/main/index/apps.json
  cache_ttl: 24h
```

本地开发可使用 file 协议或相对路径：

```bash
export CLOUD_FORGE_STORE_URL="file:///path/to/cloud-forge-catalog/index/apps.json"
```

## 贡献新应用

1. 复制 `apps/gitea/` 为 `apps/<your-app>/`
2. 编辑 `manifest.json` 与 `templates/`
3. 运行 `make validate && make index`
4. 提交 PR

当前最小可验证服务是 `hello-nginx`。它只包含 AWS CloudFormation 模板，用 Amazon Linux 2023 的公开 SSM AMI 参数安装并启动 NGINX，适合作为 CLI 与 catalog 的本地验收样例。

## 命令

```bash
make index        # 生成 index/apps.json
make validate     # 校验 manifest、模板路径、索引结构
make validate-aws # 使用 AWS SAM CLI 本地 lint AWS CloudFormation 模板
```

`make validate-aws` 只执行本地模板 lint，不创建 CloudFormation Stack，不启动 EC2，也不会分配 EIP。它适合在提交前快速发现 CloudFormation/SAM 语法和静态规则问题；AMI 是否存在、实例规格是否在目标 Region 可用、IAM 权限是否足够，仍需要后续用 Change Set 或沙箱账号验证。

本地依赖：

```bash
brew tap aws/tap
brew install aws-sam-cli
python3 -m pip install cfn-lint
```

## 版本

- Catalog 版本遵循 SemVer，通过 Git Tag 发布（如 `v1.0.0`）
- CLI 可通过 `--catalog-version v1.0.0` 锁定索引版本
