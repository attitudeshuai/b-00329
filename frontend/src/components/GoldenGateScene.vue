<script setup lang="ts">
import { onMounted, onBeforeUnmount, ref } from 'vue';
import * as THREE from 'three';
import { OrbitControls } from 'three/examples/jsm/controls/OrbitControls.js';
import { Water } from 'three/examples/jsm/objects/Water.js';
import { Sky } from 'three/examples/jsm/objects/Sky.js';

const canvasContainer = ref<HTMLDivElement | null>(null);

// Configuration
const BRIDGE_COLOR = 0xF04A00; // International Orange
const ROAD_COLOR = 0x333333;
const CABLE_COLOR = 0xF04A00;

let scene: THREE.Scene;
let camera: THREE.PerspectiveCamera;
let renderer: THREE.WebGLRenderer;
let controls: OrbitControls;
let water: Water;
let sun: THREE.Vector3;
let animationId: number;

// Cleanup helper
const cleanUp = () => {
  if (animationId) cancelAnimationFrame(animationId);
  if (renderer) renderer.dispose();
  if (controls) controls.dispose();
  window.removeEventListener('resize', onWindowResize);
};

const onWindowResize = () => {
  if (!camera || !renderer) return;
  camera.aspect = window.innerWidth / window.innerHeight;
  camera.updateProjectionMatrix();
  renderer.setSize(window.innerWidth, window.innerHeight);
};

// Generate a noise texture for water normals
function createWaterNormals(): THREE.Texture {
  const canvas = document.createElement('canvas');
  canvas.width = 512;
  canvas.height = 512;
  const context = canvas.getContext('2d');
  if (context) {
    context.fillStyle = '#8080ff'; // Default normal blue
    context.fillRect(0, 0, 512, 512);
    // Add some random noise
    for (let i = 0; i < 20000; i++) {
        const x = Math.random() * 512;
        const y = Math.random() * 512;
        const r = Math.random() * 255;
        const g = Math.random() * 255;
        // Simple noise approximation for ripples
        context.fillStyle = `rgb(${r}, ${g}, 255)`;
        context.fillRect(x, y, 2, 2);
    }
  }
  const texture = new THREE.CanvasTexture(canvas);
  texture.wrapS = THREE.RepeatWrapping;
  texture.wrapT = THREE.RepeatWrapping;
  return texture;
}

const init = () => {
  if (!canvasContainer.value) return;

  // 1. Scene Setup
  scene = new THREE.Scene();
  
  // 2. Camera
  camera = new THREE.PerspectiveCamera(55, window.innerWidth / window.innerHeight, 1, 20000);
  camera.position.set(30, 30, 100);

  // 3. Renderer
  renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(window.devicePixelRatio);
  renderer.setSize(window.innerWidth, window.innerHeight);
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 0.5;
  canvasContainer.value.appendChild(renderer.domElement);

  // 4. Controls
  controls = new OrbitControls(camera, renderer.domElement);
  controls.maxPolarAngle = Math.PI * 0.495;
  controls.target.set(0, 10, 0);
  controls.minDistance = 40.0;
  controls.maxDistance = 2000.0;
  controls.update();

  // 5. Sun & Sky
  sun = new THREE.Vector3();
  const sky = new Sky();
  sky.scale.setScalar(10000);
  scene.add(sky);

  const skyUniforms = (sky.material as THREE.ShaderMaterial).uniforms;
  skyUniforms['turbidity']!.value = 10;
  skyUniforms['rayleigh']!.value = 2;
  skyUniforms['mieCoefficient']!.value = 0.005;
  skyUniforms['mieDirectionalG']!.value = 0.8;

  const pmremGenerator = new THREE.PMREMGenerator(renderer);
  const sceneEnv = new THREE.Scene();
  let renderTarget: THREE.WebGLRenderTarget;

  const updateSun = () => {
    const theta = Math.PI * (0.45 - 0.5); // Elevation
    const phi = 2 * Math.PI * (0.25 - 0.5); // Azimuth

    sun.x = Math.cos(phi);
    sun.y = Math.sin(phi) * Math.sin(theta);
    sun.z = Math.sin(phi) * Math.cos(theta);

    (sky.material as THREE.ShaderMaterial).uniforms['sunPosition']!.value.copy(sun);

    if (renderTarget) renderTarget.dispose();
    sceneEnv.add(sky);
    renderTarget = pmremGenerator.fromScene(sceneEnv);
    scene.add(sky);
    scene.environment = renderTarget.texture;
  };
  updateSun();

  // 6. Water
  const waterGeometry = new THREE.PlaneGeometry(10000, 10000);
  water = new Water(
    waterGeometry,
    {
      textureWidth: 512,
      textureHeight: 512,
      waterNormals: createWaterNormals(),
      sunDirection: new THREE.Vector3(),
      sunColor: 0xffffff,
      waterColor: 0x001e0f,
      distortionScale: 3.7,
      fog: scene.fog !== undefined
    }
  );
  water.rotation.x = -Math.PI / 2;
  scene.add(water);

  // 7. Lighting (Atmospheric)
  const ambientLight = new THREE.AmbientLight(0xcccccc, 0.4);
  scene.add(ambientLight);

  const dirLight = new THREE.DirectionalLight(0xffaa33, 1);
  dirLight.position.set(-1, 1, 1);
  scene.add(dirLight);

  // Fog for depth
  scene.fog = new THREE.FogExp2(0xefd1b5, 0.0015); // Matches the sunset-ish vibe

  // 8. Build The Bridge
  buildBridge();

  // Event Listeners
  window.addEventListener('resize', onWindowResize);

  // Start Loop
  animate();
};

const buildBridge = () => {
  const bridgeGroup = new THREE.Group();
  scene.add(bridgeGroup);

  const towerMat = new THREE.MeshStandardMaterial({ 
    color: BRIDGE_COLOR,
    roughness: 0.7,
    metalness: 0.1
  });
  
  const roadMat = new THREE.MeshStandardMaterial({ 
    color: ROAD_COLOR,
    roughness: 0.9 
  });

  const cableMat = new THREE.MeshStandardMaterial({ 
    color: CABLE_COLOR,
    roughness: 0.5,
    metalness: 0.2
  });

  // --- Dimensions (Approximate Scaled) ---
  const towerHeight = 100; // Above water
  const towerWidth = 10;
  const towerDepth = 6;
  const span = 400; // Distance between towers
  const sideSpan = 150;
  const deckY = 25; // Height of deck above water

  // --- Helper: Create Tower ---
  const createTower = (x: number) => {
    const towerGroup = new THREE.Group();
    towerGroup.position.set(x, 0, 0);

    // Two legs
    const legGeo = new THREE.BoxGeometry(towerWidth, towerHeight, towerDepth);
    const legLeft = new THREE.Mesh(legGeo, towerMat);
    legLeft.position.set(0, towerHeight / 2, 15);
    legLeft.castShadow = true;
    legLeft.receiveShadow = true;

    const legRight = new THREE.Mesh(legGeo, towerMat);
    legRight.position.set(0, towerHeight / 2, -15);
    legRight.castShadow = true;
    legRight.receiveShadow = true;

    // Cross braces (Art Deco style)
    const braceGeo = new THREE.BoxGeometry(towerWidth - 2, 4, 30);
    const brace1 = new THREE.Mesh(braceGeo, towerMat);
    brace1.position.set(0, towerHeight * 0.9, 0);
    
    const brace2 = new THREE.Mesh(braceGeo, towerMat);
    brace2.position.set(0, towerHeight * 0.7, 0);

    const brace3 = new THREE.Mesh(braceGeo, towerMat);
    brace3.position.set(0, towerHeight * 0.5, 0);

    const brace4 = new THREE.Mesh(braceGeo, towerMat);
    brace4.position.set(0, deckY + 5, 0); // Below deck

    // Decorative top
    const topGeo = new THREE.BoxGeometry(towerWidth - 2, 10, towerDepth - 2);
    const topLeft = new THREE.Mesh(topGeo, towerMat);
    topLeft.position.set(0, towerHeight + 5, 15);
    const topRight = new THREE.Mesh(topGeo, towerMat);
    topRight.position.set(0, towerHeight + 5, -15);

    towerGroup.add(legLeft, legRight, brace1, brace2, brace3, brace4, topLeft, topRight);
    return towerGroup;
  };

  const tower1 = createTower(-span / 2);
  const tower2 = createTower(span / 2);
  bridgeGroup.add(tower1, tower2);

  // --- Deck ---
  const totalLength = span + (sideSpan * 2);
  const deckGeo = new THREE.BoxGeometry(totalLength, 2, 34); // Wide deck
  const deck = new THREE.Mesh(deckGeo, roadMat);
  deck.position.set(0, deckY, 0);
  deck.receiveShadow = true;
  bridgeGroup.add(deck);

  // --- Main Cables (Catenary) ---
  // Using quadratic curves to simulate catenary
  const createMainCable = (zOffset: number) => {
    // Left Side Span
    const curve1 = new THREE.QuadraticBezierCurve3(
      new THREE.Vector3(-span/2 - sideSpan, deckY, zOffset),
      new THREE.Vector3(-span/2 - sideSpan/2, deckY + (towerHeight - deckY)/2, zOffset), // Control point
      new THREE.Vector3(-span/2, towerHeight, zOffset)
    );

    // Center Span (The deep curve)
    const curve2 = new THREE.QuadraticBezierCurve3(
      new THREE.Vector3(-span/2, towerHeight, zOffset),
      new THREE.Vector3(0, deckY + 5, zOffset), // Low point
      new THREE.Vector3(span/2, towerHeight, zOffset)
    );

    // Right Side Span
    const curve3 = new THREE.QuadraticBezierCurve3(
      new THREE.Vector3(span/2, towerHeight, zOffset),
      new THREE.Vector3(span/2 + sideSpan/2, deckY + (towerHeight - deckY)/2, zOffset),
      new THREE.Vector3(span/2 + sideSpan, deckY, zOffset)
    );

    const points = [
        ...curve1.getPoints(20),
        ...curve2.getPoints(50),
        ...curve3.getPoints(20)
    ];

    const curvePath = new THREE.CatmullRomCurve3(points);
    const tubeGeo = new THREE.TubeGeometry(curvePath, 100, 1.5, 8, false);
    const cableMesh = new THREE.Mesh(tubeGeo, cableMat);
    bridgeGroup.add(cableMesh);

    return points;
  };

  const leftCablePoints = createMainCable(15);
  const rightCablePoints = createMainCable(-15);

  // --- Vertical Suspenders (InstancedMesh for performance) ---
  // We place a vertical line from the cable point down to the deck
  // Only for the middle span mostly, and parts of side spans
  const suspenderCount = leftCablePoints.length + rightCablePoints.length;
  const suspenderGeo = new THREE.CylinderGeometry(0.3, 0.3, 1, 8);
  const suspenderMesh = new THREE.InstancedMesh(suspenderGeo, cableMat, suspenderCount);
  
  const dummy = new THREE.Object3D();
  let idx = 0;

  [leftCablePoints, rightCablePoints].forEach(points => {
    points.forEach((p) => {
        // Only add suspenders if the point is above the deck significantly
        if (p.y > deckY + 2) {
            const height = p.y - deckY;
            dummy.position.set(p.x, deckY + height / 2, p.z);
            dummy.scale.set(1, height, 1);
            dummy.updateMatrix();
            suspenderMesh.setMatrixAt(idx++, dummy.matrix);
        }
    });
  });

  bridgeGroup.add(suspenderMesh);
};

const animate = () => {
  animationId = requestAnimationFrame(animate);
  if (water) {
    (water.material as THREE.ShaderMaterial).uniforms['time']!.value += 1.0 / 60.0;
  }
  controls.update();
  renderer.render(scene, camera);
};

onMounted(() => {
  init();
});

onBeforeUnmount(() => {
  cleanUp();
});
</script>

<template>
  <div ref="canvasContainer" class="canvas-container"></div>
  <div class="overlay">
    <h1>金门大桥</h1>
  </div>
</template>

<style scoped>
.canvas-container {
  width: 100vw;
  height: 100vh;
  position: absolute;
  top: 0;
  left: 0;
  z-index: 1;
}

.overlay {
  position: absolute;
  bottom: 30px;
  left: 30px;
  z-index: 2;
  color: white;
  font-family: 'Helvetica Neue', Arial, sans-serif;
  text-shadow: 0 2px 4px rgba(0,0,0,0.8);
  pointer-events: none;
}

.overlay h1 {
  margin: 0;
  font-size: 2.5rem;
  letter-spacing: 2px;
  font-weight: 300;
}
</style>
