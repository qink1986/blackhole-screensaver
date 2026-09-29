# 黑洞屏保

一个基于实时光线追踪的 Schwarzschild 黑洞 Windows 屏幕保护程序。

移植自 [s0xDk/ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole) — 原本是 Ghostty 终端的着色器，现在是独立的屏保程序，不需要任何终端。

## 效果

屏保启动后直接进入近黑色宇宙背景，不会采集、显示或吸入桌面内容。背景保留少量星点及两组小星团；它们的位置每次运行都会随机改变，但在本次运行中固定。只有黑洞附近的强引力透镜区域才以偏折后的星空替换固定背景，因此星像仅会在该区域发生表观位移、拉伸或遮挡。四个历史吸积盘外观（近边缘盘、侧视盘、斜视盘与接近正面盘）会在每次运行时随机排序；每 96 秒一轮，每轮各出现一次，且相邻镜头不会重复。每个外观保持约 18 秒，再用约 6 秒平滑过渡至下一外观。黑洞中心和表观尺寸沿受边界约束的缓慢 Lissajous 轨迹连续漂移，而非跳变或无约束漫游。盘内细丝和宏观亮团以较慢的共同时间轴旋转；吸积盘仍叠加低频、可环绕的亮团与暗隙，使物质密度不再只是均匀细条纹。

## 物理

每个像素都在计算自己的 Schwarzschild 零测地线。没有任何东西是"画上去"的 — 一切来自积分：

- **阴影** — 影响参数低于 `b_crit = (3√3/2) r_s` 的光线落入视界
- **引力透镜** — 逃逸光线弯曲、放大，在爱因斯坦环内形成镜像
- **吸积盘** — 开普勒盘 + Shakura–Sunyaev 黑体着色 + 相对论多普勒增亮 + 引力时间膨胀
- **光子环** — 由绕行 `1.5 r_s` 附近的光线自然涌现，不是画出来的
- **色差** — 弱场区域蓝色比红色弯曲略多

## 下载

从 [最新 Release](https://github.com/gkd2323c/blackhole-screensaver/releases/latest) 下载 `blackhole.scr`。

## 安装

1. 将 `blackhole.scr` 复制到 `%SYSTEMROOT%\System32\`
2. 右键桌面 → 个性化 → 锁屏 → 屏幕保护程序设置
3. 在下拉列表中选择 **Black Hole**
4. 点击 **设置** 可调整星空亮度、吸积盘透明度、多普勒效应强度

或者直接双击 `blackhole.scr` 预览效果。

## 从源码编译

需要 MSVC（Visual Studio Build Tools）。`build.bat` 会自动定位已安装的 Visual Studio C++ 工具链，因此可从普通 `cmd.exe` 或资源管理器直接运行；也可在 Developer Command Prompt 中手动编译：

```bat
cl /O2 /W3 /nologo /D_CRT_SECURE_NO_WARNINGS /Fe:blackhole.scr ^
    blackhole_screensaver.c opengl32.lib user32.lib gdi32.lib advapi32.lib shell32.lib comctl32.lib ^
    /link /SUBSYSTEM:WINDOWS
```

或者直接运行 `build.bat`；只有在编译真正成功时，它才会覆盖正式的 `blackhole.scr`。

## 工作原理

单个 C 文件把整个 GLSL fragment shader 作为字符串字面量内嵌。Win32 宿主创建全屏 OpenGL 3.3 上下文，编译着色器，每帧渲染一个全屏 quad。Vertex shader 用 `gl_VertexID` 生成 quad，不需要任何顶点缓冲。着色器在四个 `DiskLook` 外观之间平滑插值，并为中心和尺寸提供受边界约束的连续漂移；在盘面交点处独立合成物质密度、温度、Doppler 与束射。

- **零依赖** — 只用 Win32 API + OpenGL
- **单个 .scr 文件** — 不需要安装器、DLL、注册表条目（屏保设置管理的除外）
- **配置对话框** — 三个滑块调节视觉效果，存储在 `HKCU\Software\BlackHoleScreensaver`
- **直接开场** — `/s`、`/p` 和 `/d` 都从程序化近黑宇宙背景及四个漂移外观直接开始，不读取桌面像素
- **节制的 GPU 负载** — 100 fps 为最大提交频率（10 ms timer）；OpenGL 同步栅栏确保 GPU 忙时丢帧而不是积压完整的光线追踪帧。慢帧完成后会有受限冷却时间，避免持续占满 GPU
- **缓慢盘面运动** — 吸积盘的细丝与宏观密度共用较慢的时间轴，避免高速、屏幕锁定式旋转

## 系统要求

- Windows 10 或 11
- 支持 OpenGL 3.3 的显卡（2010 年后几乎所有显卡都支持）

## 许可证

MIT License — 详见 [LICENSE](LICENSE)。

吸积盘着色器改编自 [s0xDk/ghostty-blackhole](https://github.com/s0xDk/ghostty-blackhole)（同样 MIT License）。Windows 屏保宿主程序为原创。
