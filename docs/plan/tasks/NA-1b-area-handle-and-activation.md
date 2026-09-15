# NA-1b 面板句柄、可见区信息与窗口激活

```yaml
id: NA-1b
package: citrine-native
module: native/area
status: ready
depends-on: [NA-1]
```

前置：NA-1 已落地（`bundle exec rake` 90 runs / 259 assertions 全绿）。本任务补三处
**NA-1 启动后才定稿的接口与实测结论**（设计文档 2.2 / 2.3 / 2.5 已更新）。

## objective

1. **窗口激活（硬要求，实测结论）**：`uiControlShow` 之后窗口**不是 key window**
   （`[NSApp keyWindow]` 为 nil、`firstResponder` 为 nil）→ 一个键都收不到。
   调 `[NSApp activateIgnoringOtherApps:YES]` 之后窗口变 key，且 **area 自动成为 first responder**，
   键盘实测可达（探针 /tmp/area_focus_probe4.rb 收到 `Key=97`("a")/`32`(空格) 的按下与抬起）。
   → `App` 在 `window_show` 之后要激活应用（macOS），并提供 `activate:` 选项（默认 true）可关；
     非 macOS 平台如实降级（不谎报）。
2. **`AreaHandle`（设计 2.5）**：`ref:` 给应用的不再是裸句柄，而是带三个方法的对象：
   - `#repaint` —— 标脏 + 重绘请求；
   - `#scroll_to(x, y, w, h)` —— 滚动面板专用（`uiAreaScrollTo` 已绑；非滚动面板调用要给出清楚错误，libui 在非滚动面板上会 abort）；
   - `#focus` —— macOS 走 `[[keyWindow] makeFirstResponder: areaNSView]`（句柄用 `uiControlHandle` 取；
     探针已验证可行），其他平台返回 false 并说明。
   实现手段是 Fiddle 调 ObjC 运行时（`objc_msgSend`/`sel_registerName`/`objc_getClass`），
   **必须**：句柄是 ObjC 对象时才走这条路、失败要安静降级成 false + dev_mode 提示（不许崩）。
3. **Painter 的可见区与内容尺寸（设计 2.2）**：
   - `clip_rect` → `[ClipX, ClipY, ClipWidth, ClipHeight]`（内容坐标）；
   - `content_size` → 应用声明的尺寸（滚动面板**必须**用它，libui 在滚动面板下把
     `AreaWidth/AreaHeight` 填 0——已核对 `darwin/area.m` 的 `if (!a->scrolling)`）。
   应用按 `clip_rect` 裁剪可见内容（60×26 的网格不裁剪会卡）。
4. `on_wheel` **不存在**（libui 的 uiAreaHandler 没有滚轮回调）：若 NA-1 实现了它或文档/README
   提到它，一并删掉/改正，改成"要滚轮就用 `scroll: true` 的滚动面板 + `scroll_to`"。

## context

- [docs/design/native-area.md](../../design/native-area.md) 2.2/2.3/2.5（已更新为实测结论）
- 探针：/tmp/area_focus_probe4.rb（激活 + first responder + 真实按键投递）
- NA-1 的既有实现：`lib/citrine/native/{painter,pointer_event,timer,renderer,widgets,widgets/libui}.rb`

## path

- `citrine-native/lib/citrine/native/**`
- `citrine-native/test/**`（新增句柄/激活/可见区相关用例；真控件冒烟同步扩展）
- `citrine-native/{README.md,GOALS.md}`（用法与限制同步）

## verification

- `bundle exec rake` 全绿，且既有 area 用例不回归
- 真控件冒烟：滚动面板的 `clip_rect` 随 `scroll_to` 变化；`content_size` 等于声明值；
  激活之后 `keyWindow` 非 nil、area 是 first responder（可在子进程里用 ObjC 查询断言）
- 非 macOS 路径：`#focus`/激活要能优雅降级（用桩/模拟调用验证，不崩）
