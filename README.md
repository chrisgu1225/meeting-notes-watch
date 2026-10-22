# 记要点

给 Chris 自己用的会议文字稿。手表负责听，iPhone 负责把话说成字。停了以后只留下一篇 UTF-8 的 `.txt`，给后面的助手写纪要。

这是侧载用的 v1，不上 App Store。界面是中文，代码注释是英文。

**这台开发环境是 Linux，没有 Xcode，也没有 watchOS SDK。工程没有在这里编译过。** 下面的 Swift 是按 2026 年 10 月能查到的 Apple 接口写的（Xcode 26 / iOS 26 / watchOS 26）。拿到 Mac 上打开 `MeetingNotes.xcodeproj` 才能真正编译。

## 怎么听

1. 先在 iPhone 上打开「记要点」，允许语音识别，留在前台。
2. 手表上点「开始」。这时还没开麦克风。
3. 先对在场的人说：

   > 我用 AI 记要点，不留录音
   >
   > I'm using AI to take notes, no recording kept

4. 再点「我已经说了」。手表才向系统要麦克风，手机准备好识别之后才开始听。
5. 点「停止」。文字稿出现在 iPhone 的列表里。声音在这一步丢掉，不会变成文件。

标题可以空着。手表上的标题框能用系统听写，那是苹果自己的听写，和这场记录不是一条管道，那一小段有可能发给苹果。

## 声音不落地

这条是硬性的。

- 手表用 `AVAudioEngine` 的 tap，在内存里转成 16 kHz、单声道、16-bit PCM。
- 传给 iPhone 只用 `WCSession.sendMessageData`。不用 `transferFile`，也不用 `transferUserInfo`，因为那两个会在系统里排队，可能写到磁盘。
- 手机接不上、或者 App 不在前台时，这一小段声音直接丢掉并计数。不补存。
- 识别器只在内存里吃 `AVAudioPCMBuffer`。没有 `AVAudioRecorder`，没有 `AVAudioFile`。
- 会写到磁盘的只有文字：`sessions.json`，以及你导出的 `.txt`。

导出前，代码会拒绝把扩展名写成 wav、caf、m4a 这类文件。

App 没有自己的服务器，没有统计。会联网的只有两件事，而且都是苹果的：

- 第一次下载设备端语音模型（你也可以事先在设置里下载）。
- 你明确打开「允许苹果服务器识别」之后，经典识别这条路可能把声音缓冲发给苹果。默认关闭。关着的时候，设备端模型不可用就直接失败，不会悄悄改走网络。

## 识别放在哪

watchOS 26 的 SDK **没有** Speech 框架。watchOS 26 的发行说明把 Speech 列为不在 watchOS SDK 里。WWDC25 第 277 场也说 `SpeechTranscriber` 不包含 watchOS。所以手表不能自己做连续识别。系统听写界面只能一句一句，不适合 30–60 分钟的会。

因此：手表采麦克风，内存里传到配对的 iPhone，iPhone 上识别。

iPhone 按设置里的「识别方式」选引擎。默认是「自动」：

| 顺序 | 引擎 | 文件头里的 `Engine` | 声音出不出这台手机 | 自定义词 |
| --- | --- | --- | --- | --- |
| 1 | `DictationTranscriber`，预设 `progressiveLongDictation`，加上远场提示 | `dictation-transcriber` | 不出。这是设备端听写模型，不支持「只能联网」的语言 | 会。通过 `AnalysisContext.contextualStrings` |
| 2 | `SpeechTranscriber`，预设 `progressiveTranscription` | `speech-transcriber` | 不出。给长时间、人离麦克风稍远的会议用。第一次可能要下载模型 | **不会。** 苹果这个模型不读 contextual strings。词仍然写进 txt 文件头，给后面的助手用 |
| 3 | `SFSpeechRecognizer`，大约每 45 秒重开一段 | `sfspeech-on-device` 或 `sfspeech-server` | 设备端可以就设备端。只有开关打开且设备端不可用时才是 `apple-server` | 会。`contextualStrings` |

「自动」只在某一步准备失败时才试下一步。一场开始之后不再中途换引擎，也不会中途改走服务器。

zh-CN 和 en-AU 到底有没有设备端模型，**以这台 iPhone 当时查到的为准**，设置页的「这台手机」会列出来。不要假设每台手机都一样。`SpeechTranscriber.isAvailable` 还跟硬件有关。

语言：

- `zh-CN`：普通话，句子里可以夹英文词。这是默认。
- `en-AU`：澳大利亚英语。

自定义词默认有：Ori、Jackson、ChatGPT、Claude、Grok、Gemini、OneDrive。可以改。最多 100 个，每个尽量一两个词。苹果对 contextual strings 的建议就是这样。

## 导出的 txt

编码 UTF-8，没有 BOM，换行只用 LF（`\n`）。

第一行永远是 `MEETING_NOTES_V1`。接下来每个字段一行，`键: 值`。值里可以有冒号（时间就有）。解析时只在**第一个** `": "` 处切开。空值写成 `键:`，后面没有空格，例如 `Note:`。

遇到单独一行 `---` 就结束文件头。它后面的全部是文字稿，可以再出现 `---`。

时间一律是 **Australia/Adelaide** 的墙钟，带夏令时偏移（10 月是 `+10:30`，7 月是 `+09:30`）。

```
MEETING_NOTES_V1
Title: 工地巡查 Ori
StartedAt: 2026-10-22T14:30:00+10:30
Timezone: Australia/Adelaide
Duration: 00:42:15
DurationSeconds: 2535
Language: zh-CN
Recognition: on-device
Engine: dictation-transcriber
RecognizerLocale: zh-CN
VocabularyApplied: true
Vocabulary: Ori; Jackson; ChatGPT; Claude; Grok; Gemini; OneDrive
DroppedAudioChunks: 0
Incomplete: false
Note:
---
电梯井防水周五前要完成。交给 Jackson。纪要放到 OneDrive。
```

字段：

| 键 | 含义 |
| --- | --- |
| `Title` | 标题。空的会写成「未命名」 |
| `StartedAt` | 开始听的时刻，阿德莱德时间，`yyyy-MM-ddTHH:mm:ss±HH:mm` |
| `Timezone` | 永远是 `Australia/Adelaide` |
| `Duration` | `HH:MM:SS` |
| `DurationSeconds` | 整数秒 |
| `Language` | `zh-CN` 或 `en-AU` |
| `Recognition` | `on-device` 或 `apple-server` |
| `Engine` | 上面表格里的四个值之一 |
| `RecognizerLocale` | 识别器实际用的 locale，可能和 `Language` 不完全一样 |
| `VocabularyApplied` | `true` / `false`。长会议模型是 `false` |
| `Vocabulary` | 用 `"; "` 隔开 |
| `DroppedAudioChunks` | 丢掉的声音段数。这些声音没有文件可恢复 |
| `Incomplete` | 正常停止是 `false`。中途被杀掉、还没点停止，自动存下的稿是 `true` |
| `Note` | 给人看的一句说明，可以空 |

文字稿里如果中间断了，会单独占一行，前后有换行：

- `[GAP phone-not-foreground]` 手机不在前台
- `[GAP audio-dropped]` 声音段被丢掉
- `[GAP audio-interruption]` 麦克风被打断（例如来电）
- `[GAP recognizer-restart-failed]` 识别器连续失败

文件名：`MeetingNotes_20261022-143000_工地巡查-Ori.txt`。时间是阿德莱德时间。标题里的空格会变成 `-`，斜杠和冒号会拿掉。

导出：

- 设置里选一次文件夹。可以是 iCloud Drive，也可以是「文件」里的 Google Drive。Google Drive 要先安装，并在「文件」App 里能看见。
- 一篇稿可以「导出到已选文件夹」「另存为…」或系统分享。
- 「导出后删除 App 里的文字稿」默认关。打开后，导出成功才会删 App 里的这篇。文件夹里的 txt 还在。

后面的助手只要认第一行 `MEETING_NOTES_V1` 和那一行 `---`。不要依赖字段顺序以外的空行，但字段集合是稳定的，每篇都会有这些键。

## 在 Mac 上侧载

需要 Xcode 26 或更新（要有 iOS 26 SDK）。旧版 Xcode 没有 `SpeechAnalyzer`，编不过。

1. 用苹果帐号登录 Xcode。
2. 打开 `MeetingNotes.xcodeproj`。
3. 选中 **MeetingNotes** target → Signing & Capabilities → Team 选你的 Personal Team。**MeetingNotesWatch** 用同一个 Team。
4. 如果包名被占用，只改 `Config/Shared.xcconfig` 里的 `BUNDLE_ID_PREFIX`。iPhone 包名是这个前缀，手表是前缀加 `.watch`，手表 Info.plist 里的同伴包名会跟着变。
5. 插上 iPhone，scheme 选 **MeetingNotes**，运行。手机上信任这台开发者证书（设置 → 通用 → VPN 与设备管理）。
6. scheme 改成 **MeetingNotesWatch**，设备选已经配对的那块表，再运行一次。
7. 手机上打开「记要点」→ 设置 → 请求语音识别权限 → 下载离线模型 → 选好导出文件夹。
8. 手表上打开「记要点」。

免费个人证书大约 7 天过期，过期后重新 Run 一次。

单元测试在 **MeetingNotes** scheme 里，`Cmd+U`。它们锁住时区、txt 格式和分包，不需要真的去听。

## 已知限制

这些是平台限制，不是以后「再修一下」就能假装没有的。

- **电话、FaceTime、别的 App 的声音都拿不到。** 系统不会把通话音频交给第三方 App。来电时麦克风被打断，文字稿里会有一条 `[GAP audio-interruption]`。通话内容不会出现。
- **iPhone 必须开着这个 App 并留在前台。** 锁屏或切走之后系统会挂起它。后台那几分钟的后台任务撑不满一场 30–60 分钟的会。切走之后声音丢掉，不补录。开会时屏幕会保持常亮，建议插电。
- **手表放下手腕、屏幕灭了，可能会停。** 工程打开了手表的音频后台模式（`UIBackgroundModes = audio`），只能让已经开始的采集继续，不能在后台才开始采。watchOS 仍可能挂起 App。没有用 `WKExtendedRuntimeSession`（那是正念、自理、理疗、闹钟），也没有用运动会话，避免记一场会却在健康里开出一次锻炼。个人证书经常也签不出扩展运行时的 entitlement。
- **手表和手机要在一起，手机 App 要可达。** 传不出去的声音直接丢。手表上会显示丢掉了几段。
- **只用手表麦克风。** 没有用 iPhone 的麦克风。手表戴在腕上，会议室里的效果一般。把表放在桌上可以，但表的 App 得留在前台。
- **经典识别大约一分钟就会被苹果停掉。** 文档写的就是这个限制。这条路大约 45 秒切一段再接上，词可能在切口被切开。长会议模型和长时间听写是为了少做这种切开。
- **中英夹杂不会完美。** 自定义词只是提高那些词被认出来的机会。没有说话人分离，也没有在 App 里写纪要。
- **模拟器不能当一场真会来测。** 模拟器麦克风和模拟器之间的 WatchConnectivity 都不能代表真机。

## 先测什么

按这个顺序，在真机上：

1. Xcode 里先编过 **MeetingNotes**，再编过 **MeetingNotesWatch**。`Cmd+U` 看格式测试是不是绿的。
2. 手机打开 App，允许语音识别。设置页能看到这台手机的模型状态。先下载离线模型。
3. 手表点「开始」之后，**不要**马上出麦克风权限。先是同意页。点返回，确认没有开始听。
4. 说完那句同意的话，点「我已经说了」。手机要留在前台。说一句中英混合的话，里面带上「Grok」或「OneDrive」。点停止。手机列表里要有文字，时间是阿德莱德时间。
5. 在 Xcode 的 Devices 里下载 App 容器，搜 `.wav` `.caf` `.m4a` `.aac`。应该没有。里面可以有 `sessions.json`，那是文字。
6. 导出一篇 txt，对照上面的样例。文件夹可以先用 iCloud Drive，再试 Google Drive（Drive App 要装好）。
7. 开会中把手机切到后台，手表上应出现「不在前台」。回到手机，后面的话还能继续，中间有一条 `[GAP phone-not-foreground]`。
8. 放下手腕大约一分钟，再抬起来看字还在不在长。这是最需要你自己确认的一点，模拟器看不出来。
9. 打一个电话进来。确认通话内容没有被记进去，而且挂断后 App 还能再听。

手机列表上的「停止并保存文字」是手表连不上时的退路。
