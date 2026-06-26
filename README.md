# Doubao IME Hammerspoon

把豆包输入法留给它最有价值的部分：免费、好用的语音输入。  
把你真正顺手的输入法，继续留作主输入法。

这个项目提供一份 [Hammerspoon](https://www.hammerspoon.org/) 配置和一个一键安装脚本，用来在 macOS 上用**一个键在「豆包」和「你的主输入法」之间快速来回切**：

- 按一下右 `⌘` → 切到豆包（然后你按豆包的 `Fn` 说话）
- 再按一下右 `⌘` → 切回原输入法

目标很直接：不把豆包输入法当主输入法用，但把它当成主力语音输入工具来用——
脚本负责帮你**快速切到豆包、用完一键切回**，省掉手动在输入法菜单里翻找的麻烦。

## 为什么做这个项目

豆包输入法的 macOS 版本目前有一个很明显的矛盾：

- 它的常规输入法能力偏弱，不太适合当主输入法。
- 它的语音识别能力却不错，而且免费，单独拿来做语音输入很有价值。
- 但官方的产品形态更偏向“占住输入法入口”，导致日常使用上必须反复切换，体验并不顺。

“按一个键切到豆包语音、说完一键切回原来的输入法”

## 它做了什么

仓库内有两个核心文件：

- [install-remote.sh](./install-remote.sh)：一行命令安装入口
- [install.sh](./install.sh)：安装脚本
- [init.lua](./init.lua)：Hammerspoon 配置

安装脚本会：

- 使用 `brew install --cask hammerspoon` 安装 Hammerspoon
- 把仓库里的 `init.lua` 复制到 `~/.hammerspoon/init.lua`
- 如果目标位置已有配置：
  - 内容相同则跳过
  - 内容不同则中文询问是否替换
  - 传入 `--force` 时直接覆盖
- 在覆盖前自动备份旧配置

## 一行命令安装

直接复制下面这条命令到终端执行：

```bash
curl -fsSL https://raw.githubusercontent.com/Paxxs/Doubao-ime-hammerspoon/main/install-remote.sh | bash
```

如果你明确要覆盖现有的 `~/.hammerspoon/init.lua`，可以用：

```bash
curl -fsSL https://raw.githubusercontent.com/Paxxs/Doubao-ime-hammerspoon/main/install-remote.sh | bash -s -- --force
```

这条命令会：

- 下载本仓库的安装包到临时目录
- 自动执行安装脚本
- 安装 Hammerspoon
- 复制 `init.lua` 到 `~/.hammerspoon/init.lua`

## 从仓库安装

如果你更希望先把仓库拉到本地，再手动执行安装脚本，也可以这样做：

```bash
git clone https://github.com/Paxxs/Doubao-ime-hammerspoon.git
cd Doubao-ime-hammerspoon
chmod +x ./install.sh
./install.sh
```

如果你明确要覆盖现有的 `~/.hammerspoon/init.lua`，可以用：

```bash
./install.sh --force
```

## 安装后怎么用

1. 打开 Hammerspoon。
2. 第一次运行时，为 Hammerspoon 授予 macOS 的“辅助功能”权限。
3. 在 Hammerspoon 菜单栏图标中点击 `Reload Config`。
4. **在豆包输入法设置里，把「语音唤起方式」设为 `Fn`（地球键）。**
5. 使用流程（4 步）：
   - 按一下**右 `⌘`** → 切到豆包（屏幕中央弹「🎤 豆包 · 按 FN 说话」）
   - 按 **`Fn`** → 豆包语音条弹出，开始说话
   - 再按 **`Fn`** → 结束识别、上屏
   - 再按一下**右 `⌘`** → 切回你原来的输入法

## 当前默认行为

脚本**只负责切输入法，不碰语音触发**。语音由豆包自己的 `Fn` 唤起。

- 监听**右 `⌘`**（keycode 54；左 `⌘` 是 55，日常快捷键不受影响）
- 按右 `⌘` 时按“你现在是不是在豆包”决定方向：
  - 不在豆包 → 记住当前输入法、切到豆包
  - 在豆包 → 切回刚才记住的输入法
- 切换都会做「切换 + 读回校验 + 没切动就补切」，确保真的切到位；每次切换屏幕中央有 toast 反馈。

> **为什么要拆成右 `⌘` 切换 + `Fn` 触发两个键？**
> 豆包的语音触发要求「按触发键的那一刻豆包已经是当前输入法」。
> 如果让同一个键既切输入法、又触发语音，切换和触发会抢在一起，豆包识别不出来（实测会出现
> 按了没反应、要按好几下、或面板一闪而过）。拆开后，`Fn` 永远是在「已经切到豆包之后」才按的，
> 和你手动切到豆包再按 `Fn` 完全一样，所以稳定。代价是从 2 次按键变成 4 次，换来可靠。
>
> 也因此脚本**不需要模拟任何键**——切换交给系统输入法切换 API，触发交给你真实的 `Fn`。

## 适合谁

- 不想把豆包输入法设成主输入法
- 又想高频使用它的免费语音输入
- 希望整个过程尽量像“按一个键就开说”
- 不想每次都手动切换输入法、再切回来

## 排查与日志

脚本会把每次切换的完整上下文写到日志，方便出问题时定位：

```bash
# 实时看
tail -f ~/.hammerspoon/fn-doubao-voice.log
# 出问题后回看最近几十行
tail -n 50 ~/.hammerspoon/fn-doubao-voice.log
```

日志里几类典型指纹：

- `▶ 切到豆包 | … 命中=true（1 次/扣0ms）`：一次正常的切到豆包，零延迟到位。
- `■ 切回 … 命中=true`：一次正常的切回。
- `切换校验 +120ms：… 仍在豆包=false`：切过去后又被外部改走了（多半是你自己用 Caps Lock / 手动切了输入法；正常）。
- `命中=false`：切换本身失败了（输入法 ID 不对 / 豆包没装好 / 有别的输入法切换器在抢）。
- `守护：被夺到豆包，已夺回 …`：切回后豆包又想把输入法夺回去，脚本在窗口期内夺了回来（正常自愈）。
- `检测到 eventtap 被禁用`：系统把键盘监听杀了，脚本已自动重启；频繁出现说明回调偶有超时。

日志文件超过 512KB 会自动轮转一份 `.log.1`，不会无限增长。

> 注：语音条弹不弹是豆包自己的事，脚本不参与，所以日志里只有「切输入法」的记录。
> 若切到豆包后按 `Fn` 不出语音，先确认豆包设置里语音唤起方式是 `Fn`、且你确实先切到了豆包。

## 注意事项

- 只支持 macOS。
- 需要你已经安装豆包输入法，并在豆包设置里把**语音唤起方式设为 `Fn`（地球键）**。
- 触发切换用的是**右 `⌘`**；如果你习惯用右 `⌘` 敲快捷键，请改用左 `⌘`，或在 `init.lua` 里把 `KEYCODE_TRIGGER` 换成别的键。
- 需要 Hammerspoon 获得“辅助功能”权限，否则无法监听按键、切换输入法。
- 安装脚本不会自动合并你原有的 Hammerspoon 配置，只会替换或保留现有 `~/.hammerspoon/init.lua`。
- 如果你已有自己的 Hammerspoon 配置，建议先看清提示；脚本在覆盖前会自动备份。

## 输入法 ID

当前配置按**输入法 source id** 切换（而不是按显示名），因为豆包/微信都会注册两个同名的输入源，按名字切容易切到“裸键盘”那个、而不是带语音的拼音模式。默认使用：

```lua
local DOUBAO_SOURCE_ID = "com.bytedance.inputmethod.doubaoime.pinyin"
```

如果你机器上的输入法 ID 不一致，可以这样查到真实 ID（在 Hammerspoon 控制台执行）：

```lua
print(hs.keycodes.currentSourceID())   -- 先手动切到豆包，再执行这行看它的 id
```

把得到的 id 填回 [init.lua](./init.lua) 的 `DOUBAO_SOURCE_ID`，然后在 Hammerspoon 中重新加载配置。

配置里还有这些可调项：

- `KEYCODE_TRIGGER`：切换触发键（默认 `54` = 右 `⌘`）。换别的键就改这个 keycode。
- `FALLBACK_SOURCE_ID`：兜底输入法（默认微信输入法 `com.tencent.inputmethod.wetype.pinyin`），仅在切到豆包时没读到“原输入法”的极端情况下，切回时用它。用别的主输入法就改这里。
- `RESTORE_GUARD_SECONDS` / `RESTORE_GUARD_INTERVAL` / `RESTORE_GUARD_STABLE`：切回后“守护”豆包再次抢占的窗口参数，一般不用动。

## 可以继续自定义的地方

你可以按自己的习惯继续改：

- 切换触发键 `KEYCODE_TRIGGER`（默认右 `⌘` = 54）
- 目标豆包输入法 `DOUBAO_SOURCE_ID`、兜底输入法 `FALLBACK_SOURCE_ID`
- 切回守护参数 `RESTORE_GUARD_*`
- 与你现有 Hammerspoon 配置的整合方式
