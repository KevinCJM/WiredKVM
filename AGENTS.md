# WiredKVM 当前工作约定

- 用中文，结论先行，简短、直接。不要重复询问已经明确授权的操作。
- 当前量产候选为 CH32V407；开发测试板为 CH32V467WEU6。当前阶段不做 PCB 设计。
- 产品保留 USB-C 公头＋母头，仅用有线传输。量产预算每块低于 ¥25；打样每块低于 ¥100，争取低于 ¥50。预算不等于已确认报价。
- 量产板仅由主控侧 USB1 给整板供电；被控侧 USB2 保留数据及 VBUS 连接检测，不给整板供电、不得回灌。两端插入顺序、单独重插任一端均不得影响自动恢复。当前开发板供电问题暂不改板，见 `hardware/USB_POWER_AND_HOTPLUG_REQUIREMENTS.md`。
- 被控端采用“直接从线内运行”：应用存在线内，由 mini 的 CPU、内存临时执行；不复制到应用程序目录、不安装后台服务、不设登录启动项。首次启动或系统权限确认按 macOS 正常流程进行，不绕过授权。已有便携应用、只读程序盘和 RAM 装载固件候选，仍待实机验收，不能称为纯硬件执行或已经交付。
- 不使用 macOS 共享功能；被控机可能不是 Mac。
- Book 登录后须自动等待硬件；插入、重插、控制程序退出后均须自动恢复连接。自动服务只管理本机输入程序，保留原有辅助功能授权身份。
- 保留键鼠、自动边缘返回及两台机器内部复制粘贴。图片和文件正文走 Bulk 二进制；大文件不得阻塞输入，取消后不得阻塞新粘贴。
- 无法恢复而需要重写的部分使用 Rust；已有代码并非全部 Rust。
- 本次诊断记录只保留本机，不推送到公开 GitHub；后续公开代码提交须排除这些记录。
- 当前工程不完整。以路由 JSON 的存在性与证据状态为准；不得把缺失文件、候选构建或离线测试当成完整交付。
- 历史经过和复盘不写入本文件；放在 `docs/history/`。当前模块事实和有效防错规则分别由 `docs/repo_map.json`、`docs/pitfalls.json` 管理。

## 操作规则

- 修改前确认范围并保留原文件；不运行未经审计的历史命令、测试清理或递归删除。
- 设备操作前核对完整身份和端口角色；重新枚举后重新定位，不按旧串口名操作。
- 区分静态检查、离线测试、实机结果和用户确认；成功启动、返回码为零不等于功能通过。
- 优先保持用户当前可用的控制通路。读调试器也可能暂停 MCU；先确认诊断副作用。
- 不以绕过系统授权、隐蔽安装或全局安全设置变更来完成安装；沿用可核实的有效授权，不重复索取；历史记录本身不扩大授权。

<!-- CODEGRAPH_START -->
## CodeGraph

若项目根存在 `.codegraph/`，在定位或理解代码前先用 `codegraph_explore` 或 `codegraph explore`，再读取精确源码。若不存在，直接用 `rg` 和文件读取；不自行建立索引。
<!-- CODEGRAPH_END -->

<!-- AI-HERMES-ROUTING-PROTOCOL:BEGIN -->
# AI Hermes Routing Protocol

## Purpose

Machine-first routing protocol for downstream agents operating from the current working directory.

## Scope Boundary

- Treat `.` as the writable project boundary unless higher-priority instructions say otherwise.
- External folders may be read for task understanding, comparison, or integration analysis; do not route edits outside the target project.
- Treat external services, DB schema, and invisible callers/callees as `out_of_scope` unless directly observed from readable files.
- Keep detailed routing facts in JSON files under `docs/`. This marked section is protocol-only; the user-requested short current constraints above stay outside it. Historical records belong in `docs/history/`.

## Required Read Order

1. `AGENTS.md`
2. `docs/repo_map.json`
3. `docs/task_routes.json`
4. `docs/pitfalls.json`
5. Routed code, tests, and configs

## Routing Ownership

- `docs/task_routes.json` owns task matching, module expansion, and operational-list merge policy.
- `docs/repo_map.json` owns module facts, operational file lists, tests, configs, and regression commands.
- `docs/pitfalls.json` owns hidden contracts, recurring pitfalls, affected modules, and safe checks.
- `AGENTS.md` owns current user constraints, protocol, required read order, scope rules, and tool workflow; it must not become a historical log.
- Do not duplicate module-level file, test, config, or regression lists in `docs/task_routes.json`.

## Default Operating Sequence

1. Match the task in `docs/task_routes.json`.
2. Load `first_read_modules` from the selected route.
3. Expand into `expand_to_modules` only when route rule codes trigger.
4. Resolve `first_read_files`, `then_check_files`, `related_tests`, `related_configs`, and `minimum_regression` from `docs/repo_map.json` using `docs/task_routes.json` merge policy.
5. Load linked pitfalls from `docs/pitfalls.json`.
6. Verify claims from code, tests, configs, or command output before promoting them to routing memory.

## AI Routing Validation

- Use `skills/ai-hermes-self-evolve/scripts/validate_ai_routing.py` after editing `AGENTS.md`, `docs/repo_map.json`, `docs/task_routes.json`, `docs/pitfalls.json`, or matching service routing files.
- The validator checks route/module/pitfall references, routed path existence, git-tracked reproducibility for stable references, minimum regression command targets, and `grounding.fact_status` values.

# AI Routing Self-Evolution

- Treat `docs/ai_routing_evolution_policy.json` as governance only; routing facts belong in `docs/task_routes.json`, `docs/repo_map.json`, and `docs/pitfalls.json`.
- Update `AGENTS.md` only when protocol, required read order, scope rules, tool workflow, or user-confirmed current constraints change. Put historical events in `docs/history/`.
- Promote verified hidden contracts and recurring pitfalls to the correct JSON owner.
- Use `skills/ai-hermes-self-evolve/scripts/evolve_ai_routing.py` after code, test, config, tool, or routing changes to check coverage.
- For routing-only work, run `skills/ai-hermes-self-evolve/scripts/evolve_ai_routing.py --routing-only` with explicit changed paths.
- Re-run `skills/ai-hermes-self-evolve/scripts/validate_ai_routing.py` after routing file changes.

## Output Discipline

- Keep routing facts in JSON only.
- Keep `AGENTS.md` protocol-only within this marked routing block. Outside this block, retain only the concise current facts and working constraints explicitly requested by the user.
- Stop exploration once routing is sufficient for first-pass narrowing.
<!-- AI-HERMES-ROUTING-PROTOCOL:END -->
