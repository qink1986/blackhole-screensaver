# “Gargantua”式非均匀吸积盘：实时 GLSL 调研

**范围**：为本仓库的 C / OpenGL 3.3 单 pass 屏保提出视觉优先、可实时运行的方案；不把电影画面误称为天体物理预测。外部事实均附直接链接；“推断”和“建议”明确标注。调研日期：2026-05-25。

## 结论

**[文献事实]** 《星际穿越》的 Double Negative Gravitational Renderer（DNGR）求解的是 Kerr（自旋）黑洞时空中的**椭圆光束**传播，用光束而非孤立光线来避免 IMAX 动画闪烁；论文也明确说电影制作人为让大众易懂而对自旋及频移/强度效果作了取舍。[James、von Tunzelmann、Franklin、Thorne, 2015（开放全文）](https://doi.org/10.1088/0264-9381/32/6/065001)

**[推断]** 视觉目标的关键不是“真实的湍流 MHD”，而是：倾斜薄盘的上、下方透镜像连续地来自同一个盘面；接近侧有稳定的相对论亮度/色彩不对称；其上叠加随半径差速旋转的低频缺口、团块和细丝。最后一项可为艺术控制的密度场，而非声称是 DNS 结果。

**[建议]** 保留现有 Schwarzschild 零测地线积分和“每次穿过盘平面即累积辐射”的架构，先把 `streaks` 换成稳定的、可环绕的 `(r, φ)` 非均匀密度；随后才考虑纹理平流。这样无需先改 C 宿主、无需引入 Kerr 或电影级光束追踪，且会改善最显眼的“均匀同心条纹”问题。

## 现状与适配边界

**[仓库事实]** 当前片元着色器已经：以 48 步积分近场光线、检测与由 `DISK_INCL` 定义的盘平面相交，并在每次相交时按开普勒式 `r^-3/2` 模式移动程序噪声；它还计算局部引力项、视线相关的频移因子及 `g^beam` 增亮（[`blackhole_screensaver.glsl:239-292`](../../blackhole_screensaver.glsl#L239-L292)）。盘的倾角、温度、Doppler 混合和对比度已经是外观参数（[同文件:10-21](../../blackhole_screensaver.glsl#L10-L21)）。宿主目前没有纹理创建/采样管线（`glTex*` 不存在），因此“外部密度纹理”是第二阶段的宿主改动，而不是零成本替换。

**[文献事实]** Bruneton 的公开 WebGL2 实现是非自旋黑洞 + 吸积盘 + 星场；其方法用预计算表把每个弯曲光束与场景的相交查询变为每像素常数时间，并公开了 GLSL、预处理器和 BSD 许可证源码。[项目与实现说明](https://ebruneton.github.io/black_hole_shader/index.html)；[源码](https://github.com/ebruneton/black_hole_shader)。这比 DNGR 更适合作为可读、可移植的参考，但其表生成需要 C++/构建工具，且目标为 WebGL2，不能直接塞进本项目的 OpenGL 3.3 单文件宿主。

## 物理/电影语境与“不直接照搬 DNGR”的原因

| 结论类别 | 可确认内容 | 对本项目的含义 |
| --- | --- | --- |
| **文献事实** | DNGR 针对任意运动、任意位置相机，追踪 Kerr 时空中的椭圆光束，并处理多像、临界曲线、近捕获光线、Doppler/引力频移、强度与镜头光晕。[论文摘要与全文](https://doi.org/10.1088/0264-9381/32/6/065001) | 它是离线/电影质量的时空与抗闪烁系统，不等同于一个可复制的“Gargantua GLSL shader”。 |
| **文献事实** | 论文公开了方法和方程，但官方论文页只提供论文/PDF，并未提供 DNGR 源码或可嵌入库。[论文页](https://doi.org/10.1088/0264-9381/32/6/065001) | 不应假设可合法或技术上直接移植电影渲染器。 |
| **推断** | 本项目是 Schwarzschild、单片元 pass、每像素固定 48 步；DNGR 为 Kerr 光束追踪且服务 IMAX 连续动画。 | 直接实现其完整椭圆光束 Jacobi 场、Kerr 测地线、抗锯齿和电影调色会显著提高算力、验证和闪烁风险；对“盘有团块”这一目标收益不成比例。 |
| **建议** | 采用“Schwarzschild 透镜 + 薄盘多次相交 + 艺术化非均匀发射率”。 | 保留盘绕黑洞上下翻折这一识别特征；把自旋拖曳、精确偏振、物理辐射输运列为明确不做。 |

**版本/适用性提示**：DNGR 论文发表于 2015-02-13，描述电影专用 Kerr 渲染器；Bruneton 的公开实现标为 2020，并明确是**非旋转**模型。[DNGR 元数据](https://doi.org/10.1088/0264-9381/32/6/065001)；[Bruneton 文档](https://ebruneton.github.io/black_hole_shader/index.html)。因此二者都是方法/视觉基准，不能证明当前参数具有 Gargantua 的天体物理真实性。

## 方案比较

| 方案 | 视觉与实现 | 物理诚实度 / 成本 | 取舍 |
| --- | --- | --- | --- |
| **A. 程序化方位团块/缺口（首选）** | 在盘相交点计算 `ρ(r, φ, t)`：少量低频、`2π` 环绕的角向 blob/暗隙 + 双频细丝；角速度 `Ω(r)∝r^-3/2`，以 `density = band * ρ` 替代现有 `streaks`。 | **推断**：这是可控的发射率贴图，不是流体模拟；无纹理、每相交仅少量 hash/noise，最适合现有 GLSL 3.3。 | 最大视觉提升/最小风险；必须让坐标随盘转，而非屏幕滑动。 |
| **B. 平流湍流密度纹理（第二步）** | 增加一个 repeat 的单通道 `GL_R8`/`GL_R16F` 极坐标纹理；采样 `uv=(radialMap(r), fract(φ/2π-Ω(r)t/2π))`，可叠两张不同尺度/速度。 | **推断**：能产生稳定的“物质被差速剪切”感；需宿主上传纹理、uniform 和 mip/filter，且采样频率不足会产生闪烁。 | 当 A 的程序噪声不够细致时使用；密度纹理应是生成资源，不能冒充物理模拟数据。GPU 纹理化噪声是成熟图形实践，见 NVIDIA 的改良噪声 GPU 实现说明。[GPU Gems 2, Ch.5](https://developer.nvidia.com/gpugems/gpugems/part-i-natural-effects/chapter-5-implementing-improved-perlin-noise) |
| **C. 几何/投影（必须保留）** | 对每条弯曲光线求盘面交点，按交点的 `(r,φ)` 发光与吸收；累计前后多次穿盘而非在屏幕空间画椭圆。 | **文献事实**：DNGR 与 Bruneton 都将弯曲光路/光束和吸积盘相交作为渲染模型的一部分。[DNGR](https://doi.org/10.1088/0264-9381/32/6/065001)；[Bruneton](https://ebruneton.github.io/black_hole_shader/index.html) | 当前实现已具备核心；这是保持“盘浮在黑洞上下方”的先决条件。 |
| **D. 透镜加速/质量升级（可选，最后）** | 保持现有 live 积分；若性能或稳定性不足，再研究 Bruneton 的预计算 beam-tracing 表。 | **文献事实**：其表实现常数时间光束相交，并提供 GLSL 参考实现。[方法说明](https://ebruneton.github.io/black_hole_shader/index.html) | 不为非均匀盘而重写；预计算资源与 WebGL2 假设是迁移成本。 |
| **E. Doppler/重力频移（保留、校准）** | 以沿光线方向的气体速度计算频移 `g`，色温/谱色按 `g` 移动，亮度使用受限的 `g^p`；色调映射后再 clamp。 | **文献事实**：DNGR 报告其 Gargantua 画面考虑了 Doppler 与引力频移造成的颜色、强度变化，但电影制作对这些效果作了可读性取舍。[论文](https://doi.org/10.1088/0264-9381/32/6/065001) | 现有 `g2`/`g2^beam` 是可用近似；不要以“更亮=更多密度”混淆频移和 `ρ`。 |

## 推荐的分阶段实施计划（建议，未实施）

1. **基线与接口**：固定一个接近边缘的 Gargantua 外观（倾角接近 `π/2`），截屏比较；将 `density` 概念从颜色/频移中分离，保留当前 `band`、`g2`、`tprof` 和多次平面相交。验收：关掉非均匀项时像现版本。
2. **A：低频非均匀性**：在 `φ` 周期域加入 3–6 个种子确定的宽团块、1–3 个暗缺口；每个特征用 `φ-φ0-Ω(r)t` 平流，并加径向包络。验收：团块跨越透镜像时在上/下像中连续出现，不会在 `φ=±π` 接缝跳变。
3. **A：细丝与抗闪烁**：用两层环绕 value/noise（低频决定团块，高频只调制其边缘），限制高频对比度并用时间连续的坐标。验收：静止截图有不均匀性、运动中不出现屏幕锁定噪点或单像素抖动。
4. **相对论校准**：让密度只乘发射率；独立调 `DOPPLER_MIX`、`DISK_BEAM`、色温和曝光，以避免亮侧被白色裁剪。验收：反向旋转时亮侧随速度方向翻转，而团块的共转方向不变。
5. **B：仅在需要时加纹理**：先用离线生成的 2D 密度 atlas；宿主只增加纹理加载、repeat/mipmap、`sampler2D` 和时间/尺度 uniform。验收：与纯程序版帧时、显存和视觉对比；不达标则保留 A。
6. **可选透镜替换**：只有 profiling 表明 48 步是瓶颈或临界区闪烁无法接受时，评估 Bruneton 的预计算表；先做独立原型并核对 BSD 许可证与资源生成链。[源码许可证与结构](https://github.com/ebruneton/black_hole_shader)

## 公开可用参考（非“电影源码”）

- **权威电影/物理语境**：James *et al.*（DNEG + Kip Thorne）的开放论文，DNGR、Kerr、光束、电影艺术取舍的第一手来源。[DOI/全文](https://doi.org/10.1088/0264-9381/32/6/065001)
- **可移植的公开实现**：Eric Bruneton 的非自旋 WebGL2/GLSL 黑洞渲染器，含预处理、盘着色、透镜、Doppler 与 beaming 的公开代码（BSD）。[文档](https://ebruneton.github.io/black_hole_shader/index.html)；[仓库](https://github.com/ebruneton/black_hole_shader)
- **本项目上游的直接参照**：s0xDk 的 Ghostty shader 说明其用 live Schwarzschild 测地线积分来取代预计算表，并公开参数/公式及 MIT 源码。[仓库 README](https://github.com/s0xDk/ghostty-blackhole)；[GLSL 源](https://github.com/s0xDk/ghostty-blackhole/blob/main/blackhole.glsl)。其“Gargantua”是预设名，**不是** DNEG/DNGR 实现或验证。

## 未决问题

- 目标是“电影感优先”还是要标注为特定盘模型？前者可采用艺术化 `ρ`；后者需要规定质量、自旋、吸积率、观测频段和辐射输运模型，超出本次实时屏保范围。
- 允许增加纹理资产/GL 纹理 API 吗？若否，方案 A 仍足够；若允许，需决定资源是否嵌入 `.scr`。
- 是否要支持低端 OpenGL 3.3 GPU？这决定高频噪声层数、纹理精度和是否值得采用预计算表。
