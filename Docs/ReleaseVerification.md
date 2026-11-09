# 发布验证

PR 与标签发布共用 `.github/workflows/verify.yml`，它仅提供 `workflow_call` 入口。调用方与被调用方使用同一次事件的提交；所有检出都显式指定 `github.sha`。PR 校验的是该事件的合并提交，标签校验的是该标签事件的提交，不查询或复用先前 PR 的绿色状态。

## 首个 PR 即可验收的路径

`.github/workflows/pr-verify.yml` 是只读 PR wrapper，调用共享验证的三个 job：

1. `build-test-package`：现有非 GUI 测试、独立性能比例及 heartbeat 检查、release 构建、macOS 15 最低版本、bundle 资源、版本和签名、DMG 完整性及其内 app 签名。
2. `gui-tests`：启用 `MD2_RUN_GUI_TESTS=1` 的全部 XCTest、GUI 用例声明检查，以及原 skip allowlist 检查。
3. `artifact-handoff`：依赖前两者成功，按 job 输出的 artifact ID 下载本次运行的 DMG，校验其提交、版本及 SHA-256。

PR wrapper 的 `verify-outputs` job 随后消费共享工作流返回的公开 artifact ID 和摘要，执行与正式发布相同的下载及 Python 校验。这覆盖了 `workflow_call`、inputs、job outputs、workflow outputs 和 artifact 传递，首个 PR 无需先合入 main 或创建发布标签。只有下载/摘要步骤重复，Swift/GUI 和打包均只运行一次。

所有 PR job 均只有 `contents: read`，不使用 `pull_request_target`，不持有发布权限。

打包使用 `Scripts/package_app.sh --release` 保留正式分发的 `dev.codex.md2` 身份。无参数本地构建只生成具有独立设置与恢复目录的开发包，不安装、不修改 Launch Services。安装必须指定 `--install /absolute/Name.app`；默认编辑器变更还需 `--set-default`。CI 拒绝安装参数。Python 打包回归在临时目录执行真实脚本逻辑，替换编译、签名及系统注册工具，验证无副作用默认值和显式操作边界；它不替代真实签名或 Actions 产物验收。

## 同一份产物

构建 job 创建并检查 `Markdown2.dmg`，记录源码提交、嵌入版本和 DMG SHA-256，上传为此运行的不可变 artifact。摘要通过 job/workflow output 单独传递。

标签发布同样调用三个共享验证 job。整个调用成功后，带 `contents: write` 的发布 job 才会运行；下载时按共享工作流返回的 artifact ID，调用同一 `Scripts/verify_release_artifact.py` 核验源提交、标签和摘要。摘要错误会硬失败，不依赖下载 action 的摘要告警是否使 job 失败。发布前还核对远端标签未移动。之后仅改文件名，上传同一份字节，不重建或重新签名。

`Release` 的手动入口运行全部共享只读验证，默认版本 `v0.0.0`；写权限发布 job 整体跳过。它是后续补充入口，不作为首次 PR 验收的前置条件。GitHub 对手动触发可用性的限制不会阻塞 PR wrapper。

## 失败阻断与证据边界

测试、skip allowlist 与性能阈值不因发布而放宽。共享交接 job 用 `needs` 依赖两个测试 job；发布 job 用 `needs` 依赖整个共享调用。不存在 `continue-on-error`、`always()` 发布条件或允许失败继续上传的分支。

```sh
python3 -m unittest discover -s Tests/WorkflowTests -p 'test_*.py'
```

8 项本地交接测试覆盖正常产物及错误提交、错误版本、缺件、缺摘要、损坏字节、非法文件名和 CLI 非零退出。使用字节 fixture，只证明校验器拒绝行为，不证明 GitHub 调度或真实 DMG/app。

YAML 结构检查与本地拒绝测试属于部分证据。真实 Actions 尚未运行时，任务保持 Blocked；不得声称发布门槛已验收。首个 PR 必须确认共享三个 job 和 caller 的 `verify-outputs` 均通过。若要实证调度的失败阻断，可在独立草稿 PR 的临时提交中让一个验证步骤确定失败，观察下游交接被跳过，再恢复最终实现并重跑最终提交；不得把故障注入或放宽阈值留进生产工作流。

## Check 名称与分支保护

原顶层 `build-test-package`、`gui-tests` 现在通过 `verify` 调用，GitHub 显示名可能成为 `verify / build-test-package`、`verify / gui-tests`、`verify / artifact-handoff`，另有顶层 `verify-outputs`。必须以真实 PR 的 check 名称核对 branch protection / ruleset，防止旧 required check 永久等待或新门槛未被设为 required。本变更没有修改远端保护设置。

## 延期边界

本流程保留现有临时签名，尚不代表 Developer ID 签名或 Apple 公证。真实证书、公证与更新机制另行验收。标签保护不能由本地 YAML 代替；发布前的标签核对也不能代替不可移动标签策略。
