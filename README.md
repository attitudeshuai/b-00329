# 金门大桥 3D 模拟 (Golden Gate Bridge 3D)

这是一个使用 **Three.js** 和 **Vue 3** 构建的视觉震撼的 3D 模拟项目。它通过程序化生成几何体，实现了金门大桥的写实渲染，并包含动态的海洋、大气天空和光照效果。

## 功能特点

- **照片级视觉效果**：使用 PBR 材质、ACES 色调映射和环境光遮蔽。
- **动态环境**：包含逼真的海洋模拟（反射、折射）和基于物理的天空/太阳位置。
- **60 FPS 性能优化**：使用 `InstancedMesh` 优化大量重复几何体（如悬索）。
- **完全响应式**：兼容 PC 和移动端 (H5)。
- **程序化建模**：不依赖外部大模型文件，所有几何体由代码生成。

## 目录结构

```
/
├── frontend/           # Vue 3 前端项目源码
├── Dockerfile          # Docker 构建文件
├── docker-compose.yml  # Docker Compose 配置
├── nginx.conf          # Nginx 配置 (端口 3000)
└── README.md           # 项目说明文档
```

## 快速开始

### 前置要求

- Docker
- Docker Compose

### 启动项目

本项目已完全容器化。在项目根目录下运行以下命令即可启动：

```bash
docker-compose up -d --build
```

### 访问项目

启动完成后，请在浏览器中访问：

http://localhost:3000

## 开发指南 (本地运行)

如果你想在本地进行开发而不使用 Docker：

1. 进入前端目录：
   ```bash
   cd frontend
   ```

2. 安装依赖：
   ```bash
   npm install
   ```

3. 启动开发服务器：
   ```bash
   npm run dev
   ```

## 技术栈

- **前端框架**: Vue 3 + TypeScript + Vite
- **3D 引擎**: Three.js
- **部署**: Nginx, Docker

## 许可证

MIT
