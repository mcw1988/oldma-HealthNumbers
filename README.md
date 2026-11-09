<p align="center">
  <img src="icon-512.png" width="128" alt="HealthNumbers icon">
</p>

# HealthNumbers

在《魔兽世界："无限"》（World of Warcraft: Forever）的单位框体状态条上，常驻显示 **当前 / 最大** 数值。

适用于客户端 **1.60.1 / Interface 16001**。只做一件事：把原本"按 C 或鼠标悬停才闪现"的数值变成常驻，不改动任何框体布局、材质或战斗逻辑。

---

## 功能

- 角色栏、目标框、小队成员、焦点、宠物框的**血量条**与**法力 / 能量条**显示「当前 / 最大」
- 一个开关，点击**即时生效**，不需要 `/reload`
- 关闭后完全恢复客户端默认行为
- 不读取血量数值本身，数值由游戏自己的渲染器写入

## 安装

1. 下载本仓库（`Code → Download ZIP`），或直接克隆
2. 把 `HealthNumbers` 文件夹放进：

   ```
   World of Warcraft/_forever_/Interface/AddOns/
   ```

3. 确认目录结构是**一层**，不要多套文件夹：

   ```
   Interface/AddOns/HealthNumbers/
   ├── HealthNumbers.toc
   └── HealthNumbers.lua
   ```

   > 如果变成 `HealthNumbers/HealthNumbers/HealthNumbers.toc`，游戏不会识别。

4. 完全退出游戏，在角色选择界面左下角点「插件 / AddOns」，勾选「**血量数值**」，进入游戏

## 使用

**ESC → 选项 → 插件 →「血量数值」**

页面里只有一个勾选框：

> ☑ 显示自身 / 目标 / 小队 状态数值

**默认开启**（首次安装或从旧版升级时自动勾选，之后记住你的选择）。

- 勾选：立即显示
- 取消：立即隐藏，恢复客户端默认

另外，ESC →「插件」列表里本插件自带的勾选框是**总开关**（是否加载插件），取消后需 `/reload` 生效。

### 显示范围

| 框体 | 血量 | 法力 / 能量 |
|---|---|---|
| 角色栏 PlayerFrame | ✅ | ✅ |
| 目标框 TargetFrame | ✅ | ✅ |
| 小队成员 PartyFrame | ✅ | ✅ |
| 焦点 FocusFrame | ✅ | ✅ |
| 宠物 PetFrame | ✅ | ✅ |
| 目标的目标 | ❌ 见「已知限制」 | ❌ |

## 实现原理

游戏的状态条由 `TextStatusBarMixin` 驱动，显示条件为：

```lua
if ((self.cvar and GetCVar(self.cvar) == "1" and self.textLockable) or self.forceShow) then
    textString:Show();
elseif (self.lockShow > 0 and (not self.forceHideText)) then
    textString:Show();
```

所有渲染逻辑都读 `self.TextString`。而玩家血条（XML 里是 `parentKey="HealthBar"`）**本身没有 `TextString` 字段** —— 文字 FontString 挂在父容器 `HealthBarsContainer` 上，名叫 `HealthBarText`；法力条则在自己的 `ManaBarText` 上。

所以插件做三件事：

1. **补字段**：把找到的 FontString 赋给 `bar.TextString`，否则渲染逻辑整个空转
2. **开开关**：打开客户端自带的「状态文字」选项（`statusText`），并给每根条设 `forceShow` / `lockShow`
3. **锁格式**：`showNumeric = true` 强制「当前 / 最大」，不依赖 `statusTextDisplay` 设置

`statusText` 是持久化的界面选项，插件在 `PLAYER_LOGOUT`（含 `/reload`）时把它恢复成加载前的值，避免残留。

## 兼容性

- ✅ 《魔兽世界："无限"》1.60.1 / Interface 16001（game type `camelot`）
- ❓ 正式服 / Classic Era / 其他版本未测试，不保证可用

## 排查

游戏内输入 `/hn`，会打印：

- 设置页是否注册成功、驱动执行次数
- 每个框体根节点找到的状态条数量
- 每根状态条的 `text` / `visible` / `forceShow` / `lockShow` / `cvar` / `lockable`

## 已知限制

- **目标的目标（ToT）不显示数值**。该框体的状态条在客户端里没有文字载体（`TextString` 为空，父容器也没有可用的 FontString），插件无法在不修改框架的前提下写入。诊断显示能识别到它的 2 根条，但无处落字，故放弃。
- 数值内容由游戏渲染器负责。血量在部分场景下是 secret value，插件不读取、不计算，只控制"显示与否"。
- 只影响显示，不改变数值格式以外的任何东西（不改字体大小、颜色、位置）。

## 合规说明

本插件遵守暴雪对 UI 插件的限制：

- ❌ 不调用 `UnitHealth` / `UnitHealthMax`，不读取任何 secret value
- ❌ 无自动化操作：没有 `RunScript`、`CastSpell*`、`Click`、`UseItem`、任务交互等
- ❌ 无文件读写、无网络请求、无数据收集
- ✅ 仅使用 `hooksecurefunc`（暴雪提供的安全 hook）和普通 UI 字段读写
- ✅ 设置页通过官方 `Settings` API 注册
- ✅ 修改的 `statusText` 为客户端自带界面选项，退出时恢复原值

## 更新日志

### 2.0.1
- 开关默认改为开启：首次安装、以及从旧版双开关升级时自动勾选，之后记住用户的实际选择

### 2.0.0
- 收敛为单开关：一个勾选框控制全部状态条数值
- 去掉分组逻辑（`statusText` 为全局选项，分组隔离在该客户端上不可行）
- 移除目标的目标的 FontString 兜底（实测无效）
- 修复 `GetChecked()` 返回值类型差异导致的勾选反转
- 事件注册改为逐个容错，避免单个无效事件中断整个插件

### 1.5.2
- 修复 `driver:RegisterEvent` 遇到无效事件（`UNIT_FOCUS`）时中断初始化的问题
- 文件末尾无条件执行一次初始化

### 1.0.0
- 首个可用版本

## 许可证

[MIT](LICENSE)
