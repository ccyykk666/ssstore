# 下载设备验证：2026-11-10

用户报告 `AMD-Action:ent/download:SP`。这是 Apple 下载服务的机器验证指令，不能当作版本不存在、下载速度、证书安装或 2034 账户令牌过期处理。

## 检查结果

55 版移植了 ipatool 的 Configurator 2.21 标识，但未移植其配套的 AMD 验证运行时。这是不完整的协议适配，不能仅因请求标识更新就认为接口兼容。

可复核的上游代码（检查固定到 `536d7bacc1c579d4420d0f4d2045368dcbf68732`）：

- [`appstore_kbsync.go`](https://github.com/majd/ipatool/blob/536d7bacc1c579d4420d0f4d2045368dcbf68732/pkg/appstore/appstore_kbsync.go)：ent/download 除 kbsync 外，还调用 storeAMDProof，为当前下载地址加入设备证明请求头。
- [`appstore_amd.go`](https://github.com/majd/ipatool/blob/536d7bacc1c579d4420d0f4d2045368dcbf68732/pkg/appstore/appstore_amd.go)：证明绑定设备 GUID 和已允许的具体接口地址，不是复制一组固定请求头。
- [`store_provisioning.go`](https://github.com/majd/ipatool/blob/536d7bacc1c579d4420d0f4d2045368dcbf68732/internal/storeauth/store_provisioning.go)：SP 的设备配置流程需要 ADI 状态、挑战数据、签名运行时与后续验证。重新生成同一账户的旧 kbsync 不能等价替代它。

## 58 版修正

1. 撤销全局 Configurator 2.21 覆盖，恢复 ApplePackage 2.0.3 原始鉴权配置；ent/download 恢复现有 CoreFP/kbsync 实现对应的 Configurator 2.18 请求标识。
2. 同时识别响应头 `X-Apple-AMD-Action` 和 plist 中的 SP/RP 指令，保留显式的账户、许可、过期令牌错误优先级。
3. 仅机器验证指令触发一次兼容下载链路。兼容链路的 volumeStore 如仍要求机器验证，只尝试一次带相同版本号的 redownload；原有空 HTTP 500 → update 规则继续保持次数上限。
4. 不将该指令当作 kbsync 缓存损坏，不触发重复登录或无休止签名；明确许可错误仍交给原来的许可处理。
5. 最终失败时显示已翻译的设备验证提示，不直接显示 AMD 内部指令。日志只记录分类、端点和数值状态，不记录 AMD 数据、令牌或原始响应。

验证覆盖响应头/正文分类、零失败码、账户/许可错误优先级、固定历史版本、不重复生成 kbsync、不重复回退和取消。构建检查不代表用户账户的 Apple 实网下载验证。

这次修正没有宣称实现完整现代 AMD/ADI 验证。如果兼容接口也被 Apple 要求设备证明，仍会停止并提示验证失败；后续需要完整实现与设备身份匹配的验证流程。
