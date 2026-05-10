# 金门大桥缆绳批量实例化 (InstancedMesh) 技术分析报告

---

## 1. 项目概览

本项目使用 Vue 3 + Three.js 构建金门大桥 3D 场景。场景中涉及大量竖直悬吊索（Suspenders）的渲染，采用 `THREE.InstancedMesh` 批量实例化方案优化性能。

核心代码位于 `GoldenenGateScene.vue:287-310`。

---

## 2. 场景中的缆绳类型与渲染方式

| 类型 | 渲染方式 | 代码位置 | 数量 |
|------|----------|----------|------|
| **主缆 (Main Cable)** | 普通 `Mesh` + `TubeGeometry` | 第 248–282 行 | 2 根（左右各一） |
| **竖直悬吊索 (Suspender)** | `InstancedMesh` 批量实例化 | 第 287–310 行 | ~180 根 |
| **塔架横撑** | 普通 `Mesh` + `BoxGeometry` | 第 210–221 行 | 8 个 |

批量实例化仅用于竖直悬吊索——因为它们共享相同几何拓扑（圆柱），仅位置和高度不同。主缆因每根曲线形状不同，仍需独立 `TubeGeometry`，无法合并。

---

## 3. 批量实例化 vs 普通方式：性能差异分析

### 3.1 普通方式（如果不用 InstancedMesh）

```typescript
points.forEach((p) => {
    if (p.y > deckY + 2) {
        const height = p.y - deckY;
        const geo = new THREE.CylinderGeometry(0.3, 0.3, height, 8);
        const mesh = new THREE.Mesh(geo, cableMat);
        mesh.position.set(p.x, deckY + height / 2, p.z);
        bridgeGroup.add(mesh);
    }
});
```

问题分析：

- 每根悬吊索 = 1 个 `Mesh` 对象 = 1 次 **Draw Call**
- 约 180 根悬吊索 → **~180 次 Draw Call**
- 每根创建独立 `CylinderGeometry`，各自占用一份 GPU 顶点缓冲区
- 每帧渲染时，CPU 必须逐个向 GPU 下发 180 条绘制指令

### 3.2 InstancedMesh 方案（项目实际代码）

```typescript
const suspenderGeo = new THREE.CylinderGeometry(0.3, 0.3, 1, 8);
const suspenderMesh = new THREE.InstancedMesh(suspenderGeo, cableMat, suspenderCount);
```

- 所有悬吊索共享 **1 个 Geometry** + **1 个 Material**
- 渲染时仅 **1 次 Draw Call**，底层调用 `gl.drawArraysInstanced`
- 每个实例的差异信息（位置、缩放）编码在 4×4 矩阵中，存储于一个 `InstancedBufferAttribute`，随 Draw Call 一次性送入 GPU

### 3.3 GPU 数据上传频率对比

这是两种方案最关键的区别：

| 方案 | 顶点数据 | 变换数据 | 每帧上传行为 |
|------|----------|----------|--------------|
| **普通方式** | 每根悬吊索各有一份独立的顶点缓冲区（`CylinderGeometry`），共 ~180 份 | 每根悬吊索的模型矩阵存在 JS 端 `Mesh.matrixWorld` 中 | 每帧执行 ~180 次 Draw Call；每次调用前，CPU 将该实例的 model matrix 写入 shader uniform，然后提交一次绘制。即：**180 次"写 uniform → 提交绘制"的循环** |
| **InstancedMesh** | 只有 1 份顶点缓冲区（共享模板几何体） | 所有实例的矩阵紧凑排列在单个 `InstancedBufferAttribute` 中 | 每帧执行 1 次 Draw Call；矩阵数组作为实例化属性绑定到顶点着色器，GPU 在单次绘制中自动为每个实例索引对应的矩阵。即：**1 次"上传矩阵数组 → 提交绘制"** |

简单来说：普通方式是"逐个提交"，每帧 180 轮 CPU↔GPU 通信；InstancedMesh 是"打包提交"，每帧 1 轮通信，GPU 在内部自行分发。省的不是三角形数量，而是 CPU 向 GPU 发送绘制指令的次数和上下文切换开销。

### 3.4 性能对比总结

| 指标 | 普通方式 | InstancedMesh |
|------|----------|---------------|
| Draw Call 数量 | ~180 | **1** |
| Geometry 对象数 | ~180 | **1** |
| JS 对象数 | ~180 个 Mesh | **1 个 InstancedMesh** |
| 每帧 CPU↔GPU 通信次数 | ~180 次 | **1 次** |
| GPU 顶点缓冲区 | ~180 份 | **1 份** |
| 实际渲染三角形总数 | 不变 | 不变 |

> **核心省点**：Draw Call 是 3D 渲染最大的 CPU 端瓶颈。从 ~180 次降到 1 次，CPU 端调度开销减少约两个数量级。GPU 绘制的三角形总量不变，但调度和状态切换开销大幅降低。

---

## 4. 每根缆绳位置和方向的控制逻辑详解

### 4.1 整体流程

```
主缆曲线采样点 → 过滤低于桥面的点 → 计算每根悬吊索的高度和位置 → 构建变换矩阵 → 写入 InstancedMesh
```

### 4.2 第一步：获取主缆采样点

```typescript
const createMainCable = (zOffset: number) => {
    const curve1 = new THREE.QuadraticBezierCurve3(...);  // 左边跨
    const curve2 = new THREE.QuadraticBezierCurve3(...);  // 中跨（下凹弧线）
    const curve3 = new THREE.QuadraticBezierCurve3(...);  // 右边跨

    const points = [
        ...curve1.getPoints(20),   // 左边跨 21 个采样点
        ...curve2.getPoints(50),   // 中跨 51 个采样点
        ...curve3.getPoints(20)    // 右边跨 21 个采样点
    ];
    return points;  // 共 93 个点
};

const leftCablePoints = createMainCable(15);   // z=15 侧主缆
const rightCablePoints = createMainCable(-15);  // z=-15 侧主缆
```

每根主缆产生 93 个采样点，两侧共 186 个候选点。

### 4.3 第二步：创建单位模板几何体

```typescript
const suspenderGeo = new THREE.CylinderGeometry(0.3, 0.3, 1, 8);
```

- 半径 0.3，**高度 1**（单位高度），8 段圆周细分
- 所有实例共享这一个几何体模板
- 每根悬吊索的实际高度通过 **Y 轴缩放** 来调整，而非创建不同高度的 Geometry

`CylinderGeometry` 默认生成以原点为中心的圆柱，其 Y 轴范围是 `[-0.5, +0.5]`，底面圆心在 `(0, -0.5, 0)`，顶面圆心在 `(0, +0.5, 0)`。

### 4.4 第三步：逐点计算变换矩阵（核心逻辑）

```typescript
const dummy = new THREE.Object3D();
let idx = 0;

[leftCablePoints, rightCablePoints].forEach(points => {
    points.forEach((p) => {
        if (p.y > deckY + 2) {              // ① 过滤
            const height = p.y - deckY;       // ② 高度
            dummy.position.set(p.x, deckY + height / 2, p.z);  // ③ 位置
            dummy.scale.set(1, height, 1);    // ④ 缩放
            dummy.updateMatrix();             // ⑤ 组合矩阵
            suspenderMesh.setMatrixAt(idx++, dummy.matrix);     // ⑥ 写入实例
        }
    });
});
```

#### ① 过滤条件 `p.y > deckY + 2`

并非所有采样点都需要悬吊索。在边跨锚固端附近，主缆高度接近桥面，悬吊索极短或为零。留出 2 单位阈值避免出现退化几何体。

#### ② 高度计算 `height = p.y - deckY`

- `p.y` 是主缆上该采样点的 Y 坐标（塔顶约 100，跨中约 30）
- `deckY = 25` 是桥面高度
- 跨中悬吊索最短（约 30-25=5），塔附近最长（约 100-25=75）

#### ③ 位置 Y 的居中计算 `deckY + height / 2`

这是理解位置控制的关键。推导如下：

单位圆柱（高度=1）的 Y 范围是 `[-0.5, +0.5]`。

经过 `scale.set(1, height, 1)` 缩放后，Y 范围变为 `[-height/2, +height/2]`。

再经过 `position.y = deckY + height/2` 平移后：

```
底端 Y = (deckY + height/2) + (-height/2) = deckY          ✓ 恰好在桥面
顶端 Y = (deckY + height/2) + (+height/2) = deckY + height = p.y  ✓ 恰好在主缆点
```

位置 X 和 Z 直接沿用主缆采样点坐标，保证悬吊索与主缆在水平面上对齐。

#### ④ 缩放 `scale.set(1, height, 1)`

- X/Z 保持 1（半径不变）
- Y 缩放为 `height`，将单位圆柱拉伸到实际长度

#### ⑤⑥ 矩阵组合与写入

`dummy.updateMatrix()` 将 position + scale + rotation 组合为一个 4×4 齐次变换矩阵，`setMatrixAt(idx, matrix)` 将其写入 InstancedMesh 内部的 `InstancedBufferAttribute`。GPU 顶点着色器在处理第 `idx` 个实例时，自动读取对应矩阵，对每个顶点 `v` 执行 `v' = M · v`。

### 4.5 方向控制的完整推导

上面的逻辑有一个隐含前提：**悬吊索是竖直的**，方向恰好沿 Y 轴。下面完整推导方向为什么天然对齐，以及如果需要非竖直方向该怎么办。

#### 4.5.1 当前场景：竖直方向天然对齐

Three.js 的 `CylinderGeometry` 生成圆柱时，**对称轴沿 Y 轴**。顶点分布在 Y 轴方向从 -0.5 到 +0.5。

本项目中悬吊索从桥面竖直向上连接到主缆，方向向量是 `(0, 1, 0)`——恰好就是 Y 轴正方向。

因此：

- 圆柱默认方向 = Y 轴 = 竖直方向 = 悬吊索所需方向
- **无需任何旋转**，`dummy.rotation` 保持默认值 `(0, 0, 0)` 即可

这就是为什么代码中只设置了 `position` 和 `scale`，完全没有出现 `rotation` 相关代码——方向天然对齐，旋转为零。

#### 4.5.2 一般情况：如何控制任意方向

如果悬吊索不是竖直的（例如斜拉桥的斜拉索，方向可能是从桥面某点指向塔顶某点），则需要引入旋转来对齐方向。推导过程如下：

**已知**：

- 圆柱模板默认沿 Y 轴（方向向量 `defaultDir = (0, 1, 0)`）
- 目标方向向量 `targetDir`（从底端指向顶端）

**求解**：找到一个旋转，使 `defaultDir` 转到 `targetDir`。

**步骤**：

1. **归一化**：`targetDir.normalize()`

2. **计算旋转轴**：两向量的叉积给出旋转轴

   ```
   axis = defaultDir × targetDir
   ```

   如果 `axis` 长度为 0，说明两向量平行（同向无需旋转，反向绕任意垂直轴旋转 π）。

3. **计算旋转角**：

   ```
   angle = acos(clamp(defaultDir · targetDir, -1, 1))
   ```

4. **应用旋转**：

   ```typescript
   dummy.quaternion.setFromAxisAngle(axis.normalize(), angle);
   ```

   或使用 Three.js 封装：

   ```typescript
   dummy.quaternion.setFromUnitVectors(
       new THREE.Vector3(0, 1, 0),  // 默认方向
       targetDir                      // 目标方向
   );
   ```

5. **调整 position**：旋转后圆柱中心不再简单地位于底端与顶端的中点，需要用旋转后的偏移重新计算。更简单的方式是先定位底端再偏移：

   ```typescript
   const bottom = new THREE.Vector3(p.x, deckY, p.z);
   const top = new THREE.Vector3(p.x, p.y, p.z);
   const center = bottom.clone().add(top).multiplyScalar(0.5);

   dummy.position.copy(center);
   dummy.scale.set(1, bottom.distanceTo(top), 1);
   dummy.quaternion.setFromUnitVectors(
       new THREE.Vector3(0, 1, 0),
       top.clone().sub(bottom).normalize()
   );
   ```

**回到本项目**：当 `targetDir = (0, 1, 0)` 时：

```
axis = (0,1,0) × (0,1,0) = (0,0,0)   → 零向量，说明平行
angle = acos(1) = 0                   → 零旋转
```

`setFromUnitVectors` 内部检测到平行情况直接返回单位四元数（无旋转），验证了当前代码省略旋转的正确性。

### 4.6 变换矩阵的数学本质

当前场景中每个实例的 4×4 变换矩阵等价于：

```
M = T · S · R
```

其中 R = 单位矩阵（无旋转），因此：

```
M = T · S
```

展开为：

```
     | 1  0       0       p.x         |     | 1  0  0  p.x         |
T =  | 0  1       0       deckY+h/2   |  S =| 0  h  0  0          |
     | 0  0       1       p.z         |     | 0  0  1  0          |
     | 0  0       0       1           |     | 0  0  0  1          |

M = T · S =
| 1  0   0  p.x         |
| 0  h   0  deckY+h/2   |
| 0  0   1  p.z         |
| 0  0   0  1           |
```

GPU 顶点着色器对模板几何体的每个顶点 `v = (vx, vy, vz, 1)` 执行：

```
v' = M · v = (vx + p.x,  h·vy + deckY + h/2,  vz + p.z,  1)
```

以圆柱底面中心 `(0, -0.5, 0, 1)` 为例验证：

```
v' = (p.x,  h·(-0.5) + deckY + h/2,  p.z,  1)
   = (p.x,  deckY,  p.z,  1)    ✓ 底端在桥面
```

以圆柱顶面中心 `(0, +0.5, 0, 1)` 为例验证：

```
v' = (p.x,  h·(0.5) + deckY + h/2,  p.z,  1)
   = (p.x,  h + deckY,  p.z,  1)
   = (p.x,  p.y,  p.z,  1)      ✓ 顶端在主缆点
```

---

## 5. 技巧总结

| 技巧 | 代码体现 | 效果 |
|------|----------|------|
| **单位几何体 + Y 缩放** | `CylinderGeometry(0.3, 0.3, 1, 8)` + `scale.set(1, height, 1)` | 避免为每根创建不同高度的 Geometry，1 份顶点数据复用 |
| **Object3D 辅助构建矩阵** | `dummy.position/scale/updateMatrix` | 无需手写矩阵运算，利用 Three.js 内置组合 |
| **方向默认对齐** | 圆柱 Y 轴 = 竖直 = 悬吊索方向，rotation 为零 | 竖直场景下无需旋转，简化矩阵为 T·S |
| **条件过滤** | `p.y > deckY + 2` | 剔除无效实例，避免退化几何 |
| **单次 Draw Call** | `new InstancedMesh(geo, mat, count)` | ~180 → 1 次 Draw Call，CPU 调度开销降低两个数量级 |

---

## 6. 局限与改进方向

1. **竖直方向假设**：当前方案假设悬吊索严格竖直。若需倾斜（如斜拉桥），须用 `quaternion.setFromUnitVectors` 设置旋转，使圆柱从默认 Y 轴方向对齐到目标方向，矩阵从 `T·S` 变为 `T·R·S`。

2. **颜色不可变**：所有实例共享同一 Material。若需单根变色（如高亮选中），需调用 `suspenderMesh.setColorAt(idx, color)` 并设置 `instanceColor` 属性，在着色器中通过顶点颜色混入实例颜色。

3. **动态更新**：当前矩阵只在初始化时设置一次。若需运行时动画（如风吹晃动），须在 `animate()` 循环中重新调用 `setMatrixAt()` 并设置 `suspenderMesh.instanceMatrix.needsUpdate = true`，通知 GPU 重新上传矩阵缓冲区。

4. **实例数量预分配**：`InstancedMesh` 的 count 在创建时固定（`suspenderCount = 186`），过滤后实际写入的 `idx` 小于此值，多余的实例矩阵保持默认零矩阵。Three.js 内部会跳过矩阵全零的实例不渲染，但 GPU 仍需遍历它们。可优化为先精确计数再创建，或调用 `suspenderMesh.count = idx` 截断有效实例数。
