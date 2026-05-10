# 批量实例化缆绳渲染方案分析报告

## 1. 概述

本项目使用 Three.js 渲染金门大桥场景，其中**垂直吊索（Vertical Suspenders）**采用了 `THREE.InstancedMesh` 批量实例化技术，而**主缆绳（Main Cables）**则使用普通的 `TubeGeometry` + `Mesh` 方式。

## 2. 批量实例化 vs 普通方式：性能对比

### 2.1 普通方式（未使用 InstancedMesh）

如果每根吊索都独立创建一个 Mesh：

```javascript
// 伪代码 - 普通方式
for (let i = 0; i < suspenderCount; i++) {
    const mesh = new THREE.Mesh(geometry, material);
    scene.add(mesh);
}
```

**缺点：**

- **内存开销大**：每个 Mesh 都有自己的 matrix、material 引用、几何体引用
- **Draw Call 多**：每根吊索都是一次独立的绘制调用（Draw Call）
- **CPU-GPU 通信频繁**：每个对象的数据都要单独传输到 GPU

### 2.2 批量实例化方式（InstancedMesh）

```javascript
// GoldenGateScene.vue:290-310
const suspenderCount = leftCablePoints.length + rightCablePoints.length;
const suspenderGeo = new THREE.CylinderGeometry(0.3, 0.3, 1, 8);
const suspenderMesh = new THREE.InstancedMesh(suspenderGeo, cableMat, suspenderCount);

const dummy = new THREE.Object3D();
let idx = 0;

[leftCablePoints, rightCablePoints].forEach(points => {
    points.forEach((p) => {
        if (p.y > deckY + 2) {
            const height = p.y - deckY;
            dummy.position.set(p.x, deckY + height / 2, p.z);
            dummy.scale.set(1, height, 1);
            dummy.updateMatrix();
            suspenderMesh.setMatrixAt(idx++, dummy.matrix);
        }
    });
});
```

**优点：**

| 维度 | 普通方式 | InstancedMesh |
|------|---------|---------------|
| **几何体数量** | N 个独立几何体引用 | 1 个共享几何体 |
| **材质数量** | N 个独立材质引用 | 1 个共享材质 |
| **Draw Call** | N 次 | 1 次 |
| **内存占用** | O(N) | O(1) 基础 + O(N) 矩阵数据 |
| **CPU 开销** | 高（每个对象都要处理） | 低（批量处理） |

### 2.3 实际性能估算

根据代码中的点数配置：
- `curve1.getPoints(20)` - 左侧曲线 20 个点
- `curve2.getPoints(50)` - 中间曲线 50 个点
- `curve3.getPoints(20)` - 右侧曲线 20 个点
- 左右两侧主缆绳：`(20 + 50 + 20) × 2 = 180` 个点
- 实际吊索数量约 `160+` 根（排除靠近桥面的点）

**节省效果：**
- Draw Call：从 160+ 次 → 1 次（减少 99%+）
- 几何体/材质对象：从 160+ 对 → 1 对（减少 99%+）
- GPU 内存带宽：大幅降低

## 3. 单根缆绳的位置和方向控制机制

### 3.1 核心思路

每根吊索的位置和方向通过一个 4×4 **变换矩阵（Matrix4）** 来控制。Three.js 使用一个 `dummy` Object3D 作为辅助对象来构建这个矩阵。

### 3.2 位置控制

```javascript
// GoldenGateScene.vue:302
dummy.position.set(p.x, deckY + height / 2, p.z);
```

- **x 坐标**：`p.x` - 主缆绳上该点的 x 坐标
- **z 坐标**：`p.z` - 主缆绳上该点的 z 坐标（15 或 -15，左右两侧）
- **y 坐标**：`deckY + height / 2` - 桥面高度 + 吊索高度的一半
  - 这样设置是因为 CylinderGeometry 默认以中心为原点
  - 几何体中心位于吊索中点，使得吊索上下对称

### 3.3 长度（高度）控制

```javascript
// GoldenGateScene.vue:301-303
const height = p.y - deckY;  // 吊索长度 = 缆绳点高度 - 桥面高度
dummy.scale.set(1, height, 1);  // y 轴缩放 = 吊索长度
```

- 原始几何体高度为 1（`CylinderGeometry(0.3, 0.3, 1, 8)`）
- 通过 y 轴缩放因子 `height` 来拉伸到实际需要的长度
- x 和 z 轴保持缩放 1，保持圆柱体粗细不变

### 3.4 方向（旋转）控制

在当前实现中，吊索是**完全垂直**的，因此不需要设置旋转：

```javascript
// 代码中没有设置 dummy.rotation
// 默认旋转为 (0, 0, 0)，即保持 y 轴向上
```

**关键点：**
- CylinderGeometry 默认的轴向是 **Y 轴**
- 因此不需要旋转，直接通过 position 和 scale 就能实现垂直吊索
- 如果需要倾斜的缆绳，才需要设置 `dummy.rotation`

### 3.5 矩阵更新与应用

```javascript
// GoldenGateScene.vue:304-305
dummy.updateMatrix();  // 根据 position、scale、rotation 计算变换矩阵
suspenderMesh.setMatrixAt(idx++, dummy.matrix);  // 将矩阵存储到 InstancedMesh
```

`updateMatrix()` 内部执行的计算（简化版）：
```
Matrix = Translation × Rotation × Scale
```

每个实例的矩阵数据存储在 InstancedMesh 的 `instanceMatrix` 属性中，这是一个 `InstancedBufferAttribute`，在一次 Draw Call 中全部发送给 GPU。

## 4. 主缆绳 vs 吊索：渲染策略对比

### 4.1 主缆绳（Main Cables）- 普通方式

```javascript
// GoldenGateScene.vue:248-282
const createMainCable = (zOffset: number) => {
    // 用三次贝塞尔曲线模拟悬链线
    const curve1 = new THREE.QuadraticBezierCurve3(...);
    const curve2 = new THREE.QuadraticBezierCurve3(...);
    const curve3 = new THREE.QuadraticBezierCurve3(...);
    
    const points = [...curve1.getPoints(20), ...curve2.getPoints(50), ...curve3.getPoints(20)];
    const curvePath = new THREE.CatmullRomCurve3(points);
    const tubeGeo = new THREE.TubeGeometry(curvePath, 100, 1.5, 8, false);
    const cableMesh = new THREE.Mesh(tubeGeo, cableMat);
};
```

**为什么主缆绳不用 InstancedMesh？**

1. **形状不同**：每根主缆绳是一条复杂的曲线，形状独特
2. **数量少**：只有 2 根主缆绳（左右各一）
3. **几何体复杂**：TubeGeometry 有很多顶点，无法简单复用

### 4.2 吊索（Suspenders）- InstancedMesh 方式

```javascript
// GoldenGateScene.vue:287-310
const suspenderGeo = new THREE.CylinderGeometry(0.3, 0.3, 1, 8);
const suspenderMesh = new THREE.InstancedMesh(suspenderGeo, cableMat, suspenderCount);
```

**为什么吊索适合用 InstancedMesh？**

1. **形状相同**：都是圆柱体，只是位置和长度不同
2. **数量多**：160+ 根
3. **几何体简单**：CylinderGeometry 顶点数少，容易复用

## 5. 技术细节深入

### 5.1 InstanceMatrix 的数据结构

InstancedMesh 内部维护一个 `Float32Array` 来存储所有实例的矩阵：

```
每个矩阵 16 个浮点数
总大小 = 实例数量 × 16 × 4 字节

对于 180 个实例：
180 × 16 × 4 = 11,520 字节（约 11KB）
```

相比之下，普通 Mesh 方式每个对象需要：
- 至少 1 个 Mesh 对象（约几十个属性）
- 1 个 Matrix4（64 字节）
- 各种内部引用
- 总计每个对象几百字节 → 180 个对象就是几十 KB，还不包括 Draw Call 开销

### 5.2 GPU 侧的工作原理

在顶点着色器中，每个顶点会乘以对应实例的矩阵：

```glsl
// 伪代码 - GPU 顶点着色器
attribute mat4 instanceMatrix;  // InstancedBufferAttribute

void main() {
    vec4 worldPosition = instanceMatrix * vec4(position, 1.0);
    gl_Position = projectionMatrix * viewMatrix * worldPosition;
}
```

GPU 可以高效地并行处理所有实例，这就是为什么单次 Draw Call 就能渲染所有实例。

### 5.3 过滤逻辑

```javascript
// GoldenGateScene.vue:300
if (p.y > deckY + 2) {
    // 只有当缆绳点显著高于桥面时才添加吊索
}
```

这个过滤避免了在桥面高度附近创建很短或零长度的吊索，优化了视觉效果和性能。

## 6. 代码优化建议

### 6.1 优化点 1：预先计算实例数量

当前代码先预估最大数量，然后可能有浪费：

```javascript
const suspenderCount = leftCablePoints.length + rightCablePoints.length;
// 但实际 idx 可能小于 suspenderCount
```

**建议：** 先遍历收集有效点，再创建 InstancedMesh：

```javascript
const validPoints: THREE.Vector3[] = [];
[leftCablePoints, rightCablePoints].forEach(points => {
    points.forEach(p => {
        if (p.y > deckY + 2) validPoints.push(p);
    });
});
const suspenderMesh = new THREE.InstancedMesh(suspenderGeo, cableMat, validPoints.length);
```

### 6.2 优化点 2：设置 instanceMatrix.needsUpdate

当前代码缺少显式标记更新：

```javascript
// 在循环结束后添加
suspenderMesh.instanceMatrix.needsUpdate = true;
```

虽然 Three.js 在某些情况下会自动处理，但显式设置更安全。

### 6.3 优化点 3：共享 dummy 对象

当前实现已经做得很好，使用了一个共享的 dummy Object3D 来避免创建大量临时对象。

## 7. 总结

| 特性 | 说明 |
|------|------|
| **批量实例化优势** | 减少 Draw Call、降低内存开销、提升渲染性能 |
| **位置控制** | 通过 `dummy.position.set(x, y, z)` 设置圆柱体中心 |
| **长度控制** | 通过 `dummy.scale.set(1, height, 1)` 沿 Y 轴拉伸 |
| **方向控制** | 吊索保持垂直，无需旋转（利用 CylinderGeometry 的默认轴向） |
| **矩阵应用** | `updateMatrix()` 计算变换矩阵，`setMatrixAt()` 存储到 InstancedMesh |
| **适用场景** | 大量形状相同、仅位置/方向/尺寸不同的对象 |

这种方案是 Three.js 中渲染大量重复几何体的标准最佳实践，在保持视觉效果的同时，显著提升了性能。
