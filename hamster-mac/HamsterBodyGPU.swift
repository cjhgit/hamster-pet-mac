import AppKit
import Metal
import SceneKit
import simd

/// The same authored implicit surface as the CPU reference, meshed entirely on
/// Metal. Output buffers are immutable after completion, so SceneKit can retain
/// an older frame while the next frame is generated without a read/write race.
@MainActor final class HamsterBodyGPU {
    struct Mesh {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let vertexCount: Int
        let indexCount: Int
        let bounds: (min: SCNVector3, max: SCNVector3)

        func positionsForInspection() -> [SIMD3<Float>] {
            let p = vertices.contents().assumingMemoryBound(to: Float.self)
            return (0..<vertexCount).map { SIMD3(p[$0 * 8], p[$0 * 8 + 1], p[$0 * 8 + 2]) }
        }
    }
    enum Failure: Error { case allocation, capacity, command(String) }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [MTLComputePipelineState]
    private var outputHeap: MTLHeap?
    private var workspace: [String: MTLBuffer] = [:]
    private var generation: UInt32 = 0
    private(set) var latest: Mesh?
    private(set) var generatedFrames = 0
    private(set) var lastGPUSeconds = 0.0
    private let vertexCapacity = 65_536
    private let indexCapacity = 393_216

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw Failure.allocation }
        self.queue = queue
        queue.label = "Hamster body meshing"
        let options = MTLCompileOptions()
        options.languageVersion = .version2_4
        if #available(macOS 15, *) {
            options.mathMode = .safe
            options.mathFloatingPointFunctions = .precise
        } else {
            options.fastMathEnabled = false
        }
        let library = try device.makeLibrary(source: Self.source, options: options)
        pipelines = try ["sampleField", "intersections", "triangulate", "relaxSkin", "skinNormals", "packSkin"].map {
            guard let function = library.makeFunction(name: $0) else { throw Failure.command($0) }
            return try device.makeComputePipelineState(function: function)
        }
        if device.supportsFamily(.apple1), !CommandLine.arguments.contains("--hamster-no-heap") {
            let descriptor = MTLHeapDescriptor()
            descriptor.size = 16 * 1024 * 1024
            descriptor.storageMode = .shared
            descriptor.hazardTrackingMode = .untracked
            outputHeap = device.makeHeap(descriptor: descriptor)
            outputHeap?.label = "Immutable hamster frame outputs"
        }
    }

    private func outputBuffer(_ bytes: Int) -> MTLBuffer? {
        // Automatic heap allocation reclaims space only when the old resource
        // is released, including references held by in-flight rendering. Never
        // alias or overwrite SceneKit's previous frame. Fall back if it retains
        // more frames than fit, or the GPU cannot use a shared heap.
        if let buffer = outputHeap?.makeBuffer(length: bytes, options: [.storageModeShared, .hazardTrackingModeUntracked]) { return buffer }
        return device.makeBuffer(length: bytes, options: .storageModeShared)
    }

    private func buffer(_ name: String, _ bytes: Int, shared: Bool = false) throws -> MTLBuffer {
        if let current = workspace[name], current.length >= bytes { return current }
        var capacity = 4096
        while capacity < bytes { capacity *= 2 }
        guard let result = device.makeBuffer(length: capacity, options: shared ? .storageModeShared : .storageModePrivate) else { throw Failure.allocation }
        result.label = "Hamster \(name)"
        workspace[name] = result
        return result
    }

    func update(engine: UnsafeMutableRawPointer) throws -> Mesh? {
        let field = HamsterEngineBuildBodyField(engine)
        guard let values = field.values, field.floatCount == 524 * 4 else { throw Failure.capacity }
        guard field.generation != generation else { return nil }
        let nx = Int(values[36]), ny = Int(values[37]), nz = Int(values[38])
        let gridCount = nx * ny * nz
        guard nx > 1, ny > 1, nz > 1, gridCount < 1_500_000 else { throw Failure.capacity }
        let parameters = try buffer("parameters", Int(field.floatCount) * 4, shared: true)
        parameters.contents().copyMemory(from: values, byteCount: Int(field.floatCount) * 4)
        guard let vertices = outputBuffer(vertexCapacity * 32),
              let indices = outputBuffer(indexCapacity * 4),
              let command = queue.makeCommandBuffer() else { throw Failure.allocation }
        vertices.label = "Hamster GPU skin vertices"
        indices.label = "Hamster GPU skin indices"
        let grid = try buffer("field lattice", gridCount * 4)
        let edges = try buffer("shared edges", gridCount * 7 * 4)
        let raw = try buffer("intersections", vertexCapacity * 16)
        let neighbors = try buffer("neighbors", vertexCapacity * 16)
        let relaxed = try buffer("relaxed skin", vertexCapacity * 16)
        let normals = try buffer("normals", vertexCapacity * 16)
        let counters = try buffer("counters", 16, shared: true)
        guard let clear = command.makeBlitCommandEncoder() else { throw Failure.allocation }
        clear.fill(buffer: counters, range: 0..<16, value: 0)
        clear.fill(buffer: neighbors, range: 0..<(vertexCapacity * 16), value: 0)
        clear.fill(buffer: normals, range: 0..<(vertexCapacity * 16), value: 0)
        clear.endEncoding()
        guard let encoder = command.makeComputeCommandEncoder() else { throw Failure.allocation }
        let buffers = [parameters, grid, edges, raw, indices, neighbors, relaxed, normals, vertices, counters]
        for (i, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: i) }
        let counts = [gridCount, gridCount * 7, (nx - 1) * (ny - 1) * (nz - 1), vertexCapacity, indexCapacity / 3, vertexCapacity]
        for (pipeline, count) in zip(pipelines, counts) {
            encoder.setComputePipelineState(pipeline)
            encoder.dispatchThreads(.init(width: count, height: 1, depth: 1),
                                    threadsPerThreadgroup: .init(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            encoder.memoryBarrier(scope: .buffers)
        }
        encoder.endEncoding()
        command.commit()
        // Only counters are read by normal playback. All surface vertices and
        // indices stay in the Metal buffers consumed directly by SceneKit.
        command.waitUntilCompleted()
        guard command.status == .completed else { throw Failure.command(command.error?.localizedDescription ?? "Metal command failed") }
        let counter = counters.contents().assumingMemoryBound(to: UInt32.self)
        let vertexCount = Int(counter[0]), indexCount = Int(counter[1])
        guard counter[2] == 0, vertexCount > 0, vertexCount <= vertexCapacity,
              indexCount > 0, indexCount <= indexCapacity, indexCount % 3 == 0 else { throw Failure.capacity }
        let lo = SIMD3<Float>(values[32], values[33], values[34])
        let hi = lo + SIMD3<Float>(Float(nx - 1), Float(ny - 1), Float(nz - 1)) * values[35]
        let mesh = Mesh(vertices: vertices, indices: indices, vertexCount: vertexCount, indexCount: indexCount,
                        bounds: (.init(lo.x, lo.y, lo.z), .init(hi.x, hi.y, hi.z)))
        generation = field.generation
        latest = mesh
        generatedFrames += 1
        lastGPUSeconds = max(0, command.gpuEndTime - command.gpuStartTime)
        return mesh
    }

    private static let source = #"""
#include <metal_stdlib>
using namespace metal;
constant uint VertexCapacity = 65536;
constant uint IndexCapacity = 393216;
constant uint Invalid = 0xffffffff;
struct Sum { atomic_uint x, y, z, w; };
struct Vertex { packed_float3 position; packed_float3 normal; float2 uv; };
inline void addFloat(device atomic_uint &target, float value) {
    uint old = atomic_load_explicit(&target, memory_order_relaxed);
    while (!atomic_compare_exchange_weak_explicit(&target, &old, as_type<uint>(as_type<float>(old) + value), memory_order_relaxed, memory_order_relaxed)) {}
}
inline void addSum(device Sum &target, float3 value, float weight) {
    addFloat(target.x, value.x); addFloat(target.y, value.y); addFloat(target.z, value.z); addFloat(target.w, weight);
}
inline float4 readSum(device Sum &source) {
    return float4(as_type<float>(atomic_load_explicit(&source.x, memory_order_relaxed)),
                  as_type<float>(atomic_load_explicit(&source.y, memory_order_relaxed)),
                  as_type<float>(atomic_load_explicit(&source.z, memory_order_relaxed)),
                  as_type<float>(atomic_load_explicit(&source.w, memory_order_relaxed)));
}
inline float3 headLocal(float3 p, device const float4 *f) {
    float3 d = p - f[4].xyz;
    return float3(dot(d, f[5].xyz), dot(d, f[6].xyz), dot(d, f[7].xyz));
}
inline float torso(float3 p, device const float4 *f) {
    float3 d = p - f[0].xyz;
    float x = dot(d, f[1].xyz), y = dot(d, f[2].xyz), z = dot(d, f[3].xyz);
    float s = clamp((x / f[0].w + 1) * 128, 0.0f, 256.0f);
    uint i = min(255u, uint(s));
    float4 a = mix(f[10 + i], f[11 + i], s - float(i));
    float cy = (a.x + a.y) * 0.5f, ry = max(0.2f, (a.y - a.x) * 0.5f), rz = z >= 0 ? a.z : a.w;
    float2 q = float2((y - cy) / ry, z / rz);
    return max((length(q) - 1) * min(ry, rz), abs(x) - f[0].w);
}
inline float skull(float3 p, device const float4 *f) {
    float3 local = headLocal(p, f);
    float s = clamp((local.x + 15) * 256 / 51, 0.0f, 256.0f);
    uint i = min(255u, uint(s));
    float4 a = mix(f[267 + i], f[268 + i], s - float(i));
    float2 q = float2((local.y - a.x) / a.y, local.z / a.z);
    return max((length(q) - 1) * min(a.y, a.z), max(-15 - local.x, local.x - 36));
}
inline float distanceField(float3 p, device const float4 *f) {
    float a = torso(p,f), b = skull(p,f), h = max(4 - abs(a-b), 0.0f) / 4;
    return min(a,b) - h*h;
}
inline uint lattice(uint3 p, uint3 dims) { return (p.z * dims.y + p.y) * dims.x + p.x; }
inline uint3 coordinate(uint i, uint3 dims) { return uint3(i % dims.x, i / dims.x % dims.y, i / (dims.x * dims.y)); }
kernel void sampleField(device const float4 *f [[buffer(0)]], device float *grid [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    uint3 dims = uint3(f[9].xyz);
    if (id >= dims.x * dims.y * dims.z) return;
    grid[id] = distanceField(f[8].xyz + float3(coordinate(id,dims)) * f[8].w, f);
}
kernel void intersections(device const float4 *f [[buffer(0)]], device const float *grid [[buffer(1)]],
                          device uint *edges [[buffer(2)]], device float4 *raw [[buffer(3)]],
                          device atomic_uint *counts [[buffer(9)]], uint key [[thread_position_in_grid]]) {
    uint3 dims = uint3(f[9].xyz); uint start = key / 7, mask = key % 7 + 1;
    if (start >= dims.x * dims.y * dims.z) return;
    uint3 a = coordinate(start,dims), b = a + uint3(mask & 1, (mask >> 1) & 1, (mask >> 2) & 1);
    edges[key] = Invalid;
    if (any(b >= dims)) return;
    float da = grid[start], db = grid[lattice(b,dims)];
    if ((da < 0) == (db < 0)) return;
    uint index = atomic_fetch_add_explicit(&counts[0], 1u, memory_order_relaxed);
    if (index >= VertexCapacity) { atomic_store_explicit(&counts[2],1u,memory_order_relaxed); return; }
    float t = da / (da-db);
    raw[index] = float4(f[8].xyz + (float3(a) + float3(b-a)*t) * f[8].w, 0);
    edges[key] = index;
}
constant uint3 Corners[8] = {uint3(0,0,0),uint3(1,0,0),uint3(1,1,0),uint3(0,1,0),uint3(0,0,1),uint3(1,0,1),uint3(1,1,1),uint3(0,1,1)};
constant uint4 Tetra[6] = {uint4(0,5,1,6),uint4(0,1,2,6),uint4(0,2,3,6),uint4(0,3,7,6),uint4(0,7,4,6),uint4(0,4,5,6)};
inline uint edge(uint a, uint b, thread const uint *gridIndex, device const uint *edges) {
    uint3 delta = uint3(abs(int3(Corners[a])-int3(Corners[b])));
    uint mask = delta.x + 2*delta.y + 4*delta.z;
    return edges[min(gridIndex[a],gridIndex[b])*7 + mask-1];
}
inline void emitTriangle(uint a, uint b, uint c, float3 outward, device const float4 *raw,
                         device uint *indices, device Sum *neighbors, device atomic_uint *counts) {
    if (a == Invalid || b == Invalid || c == Invalid) return;
    float3 pa=raw[a].xyz, pb=raw[b].xyz, pc=raw[c].xyz;
    float3 n=cross(pb-pa,pc-pa);
    if (dot(n,outward)<0) { uint temp=b;b=c;c=temp;float3 p=pb;pb=pc;pc=p; }
    uint at=atomic_fetch_add_explicit(&counts[1],3u,memory_order_relaxed);
    if (at+3>IndexCapacity) { atomic_store_explicit(&counts[2],1u,memory_order_relaxed);return; }
    indices[at]=a;indices[at+1]=b;indices[at+2]=c;
    float area=length(n);
    addSum(neighbors[a],(pb+pc)*(0.5f*area),area);
    addSum(neighbors[b],(pc+pa)*(0.5f*area),area);
    addSum(neighbors[c],(pa+pb)*(0.5f*area),area);
}
kernel void triangulate(device const float4 *f [[buffer(0)]], device const float *grid [[buffer(1)]],
                        device const uint *edges [[buffer(2)]], device const float4 *raw [[buffer(3)]],
                        device uint *indices [[buffer(4)]], device Sum *neighbors [[buffer(5)]],
                        device atomic_uint *counts [[buffer(9)]], uint id [[thread_position_in_grid]]) {
    uint3 dims=uint3(f[9].xyz), cells=dims-1;
    if (id>=cells.x*cells.y*cells.z) return;
    uint3 base=coordinate(id,cells);uint gridIndex[8];float3 p[8];float d[8];uint insideCount=0;
    for(uint i=0;i<8;i++) {gridIndex[i]=lattice(base+Corners[i],dims);d[i]=grid[gridIndex[i]];insideCount+=d[i]<0;}
    if(insideCount==0 || insideCount==8) return;
    for(uint i=0;i<8;i++) p[i]=f[8].xyz+float3(base+Corners[i])*f[8].w;
    for(uint k=0;k<6;k++) {
        uint in[4],out[4],ni=0,no=0;
        for(uint j=0;j<4;j++){uint a=Tetra[k][j];if(d[a]<0)in[ni++]=a;else out[no++]=a;}
        if(ni==0 || no==0) continue;
        float3 ip=0,op=0;for(uint i=0;i<ni;i++)ip+=p[in[i]];for(uint i=0;i<no;i++)op+=p[out[i]];
        float3 outward=op/float(no)-ip/float(ni);
        if(ni==1)emitTriangle(edge(in[0],out[0],gridIndex,edges),edge(in[0],out[1],gridIndex,edges),edge(in[0],out[2],gridIndex,edges),outward,raw,indices,neighbors,counts);
        else if(ni==3)emitTriangle(edge(out[0],in[0],gridIndex,edges),edge(out[0],in[1],gridIndex,edges),edge(out[0],in[2],gridIndex,edges),outward,raw,indices,neighbors,counts);
        else {
            uint a=edge(in[0],out[0],gridIndex,edges),b=edge(in[0],out[1],gridIndex,edges),c=edge(in[1],out[0],gridIndex,edges),d0=edge(in[1],out[1],gridIndex,edges);
            emitTriangle(a,b,c,outward,raw,indices,neighbors,counts);emitTriangle(b,d0,c,outward,raw,indices,neighbors,counts);
        }
    }
}
kernel void relaxSkin(device const float4 *raw [[buffer(3)]], device Sum *neighbors [[buffer(5)]],
                      device float4 *relaxed [[buffer(6)]], device atomic_uint *counts [[buffer(9)]], uint id [[thread_position_in_grid]]) {
    if(id>=min(VertexCapacity,atomic_load_explicit(&counts[0],memory_order_relaxed)))return;
    float4 n=readSum(neighbors[id]);
    relaxed[id]=float4(n.w>1e-12f ? raw[id].xyz*0.85f+(n.xyz/n.w)*0.15f : raw[id].xyz,0);
}
kernel void skinNormals(device const uint *indices [[buffer(4)]], device const float4 *relaxed [[buffer(6)]],
                        device Sum *normals [[buffer(7)]], device atomic_uint *counts [[buffer(9)]], uint id [[thread_position_in_grid]]) {
    if(id>=min(IndexCapacity,atomic_load_explicit(&counts[1],memory_order_relaxed))/3)return;
    uint a=indices[id*3],b=indices[id*3+1],c=indices[id*3+2];
    float3 n=cross(relaxed[b].xyz-relaxed[a].xyz,relaxed[c].xyz-relaxed[a].xyz);
    addSum(normals[a],n,0);addSum(normals[b],n,0);addSum(normals[c],n,0);
}
constant float2 SideMark[7] = {float2(32,1),float2(35,2),float2(33,9),float2(25,12),float2(3,11),float2(8,6),float2(23,6)};
constant float2 FrontMark[7] = {float2(3,1),float2(0,2),float2(0,9),float2(0,12),float2(8,11),float2(15,6),float2(8,6)};
inline float marking(float2 p, constant float2 *polygon) {
    bool inside=false;float nearest=1e9;
    for(uint i=0,j=6;i<7;j=i++) {
        float2 a=polygon[j],b=polygon[i],delta=b-a;
        if((a.y>p.y)!=(b.y>p.y) && p.x<(b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x)inside=!inside;
        float l2=dot(delta,delta),t=l2>1e-9f?clamp(dot(p-a,delta)/l2,0.0f,1.0f):0;
        nearest=min(nearest,length(p-a-t*delta));
    }
    return clamp(0.5f+(inside?nearest:-nearest)/0.35f,0.0f,1.0f);
}
kernel void packSkin(device const float4 *f [[buffer(0)]], device const float4 *relaxed [[buffer(6)]],
                     device Sum *normals [[buffer(7)]], device Vertex *vertices [[buffer(8)]],
                     device atomic_uint *counts [[buffer(9)]], uint id [[thread_position_in_grid]]) {
    if(id>=min(VertexCapacity,atomic_load_explicit(&counts[0],memory_order_relaxed)))return;
    float3 p=relaxed[id].xyz,n=readSum(normals[id]).xyz;float l2=dot(n,n);
    n=l2>1e-20f?n*rsqrt(l2):float3(0,1,0);
    float3 local=headLocal(p,f);float coat=0;
    if(local.x>0 && local.x<36 && local.y>-.5f && local.y<13) {
        float front=clamp((dot(n,f[5].xyz)-abs(dot(n,f[7].xyz))+.2f)/.4f,0.0f,1.0f);
        coat=mix(marking(local.xy,SideMark),marking(float2(abs(local.z),local.y),FrontMark),front);
        if(coat>0)coat*=clamp((torso(p,f)-skull(p,f)+2)/4,0.0f,1.0f);
    }
    vertices[id].position=packed_float3(p);vertices[id].normal=packed_float3(n);vertices[id].uv=float2(coat,.5f);
}
"""#
}
