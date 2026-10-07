//! `api`: the public WebGPU surface, generated from `dawn.json`.
//!
//! **What this module is.** `docs/10-architecture.md` "Module boundaries" gives
//! `api` the handles, the descriptors and the enums, and nothing else.
//! `docs/30-port-design.md` §8.1 owns the generator and `tools/gen_api.zig` is
//! it: `api.zig` is the generated aggregate, and the eleven files beside it are
//! the areas that aggregate is split into.
//!
//! **What this module does not claim.** It holds no engine state and it
//! validates nothing. Every name here is a value a caller builds and compares;
//! the rules that read one live in `command`, `pipeline` and `engine`, which is
//! what lets a descriptor be tested with no device. Nor does it claim Dawn's
//! wire format: `docs/30-port-design.md` §4.3 owns that decision, and the
//! chained structs below are the port's own.
//!
//! **Why this file is hand-written.** Zig 0.16 has no `usingnamespace`, so a
//! root in front of a generated aggregate can only name what it re-exports.
//! Naming it here keeps `src/api/api.zig` a file no human edits, which is what
//! `AGENTS.md` §3.1 asks of a generated file and what lets `zig build generate`
//! rewrite it. The cost is one line per generated export: a name added to
//! `dawn.json` needs a line in the list below before a consumer can reach it.
//!
//! **How to read this file.** The eleven area namespaces are the generated
//! aggregate's own names, so they need no line of their own; `api` is the
//! generated file as one namespace, and every other line is a flat re-export of
//! one generated name.

/// The generated aggregate. Nothing below imports it directly, because the
/// generated file is not the published surface — this file is.
const generated = @import("api.zig");

/// `api.zig`, the whole generated file as one namespace. Every name below is
/// reachable through it as well as through the module.
pub const api = generated;

// The generated surface, one name per line, in the order `sort` gives so that a
// line added by the generator is easy to place. The eleven area namespaces
// (`bitmask`, `callbacks`, `chained`, `constants`, `descriptors`, `enums`,
// `errors`, `handled`, `natives`, `objects`, `proc`) are in this list already:
// they are whole-file namespaces the generator emits.
pub const AHardwareBufferProperties = generated.AHardwareBufferProperties;
pub const Adapter = generated.Adapter;
pub const AdapterInfo = generated.AdapterInfo;
pub const AdapterPropertiesD3D = generated.AdapterPropertiesD3D;
pub const AdapterPropertiesDrm = generated.AdapterPropertiesDrm;
pub const AdapterPropertiesMemoryHeaps = generated.AdapterPropertiesMemoryHeaps;
pub const AdapterPropertiesSubgroupMatrixConfigs = generated.AdapterPropertiesSubgroupMatrixConfigs;
pub const AdapterPropertiesVk = generated.AdapterPropertiesVk;
pub const AdapterPropertiesWGPU = generated.AdapterPropertiesWGPU;
pub const AdapterType = generated.AdapterType;
pub const AddressMode = generated.AddressMode;
pub const AlphaMode = generated.AlphaMode;
pub const ArrayLayerCountUndefined = generated.ArrayLayerCountUndefined;
pub const AsyncStartError = generated.AsyncStartError;
pub const BackendType = generated.BackendType;
pub const BindGroup = generated.BindGroup;
pub const BindGroupDescriptor = generated.BindGroupDescriptor;
pub const BindGroupEntry = generated.BindGroupEntry;
pub const BindGroupLayout = generated.BindGroupLayout;
pub const BindGroupLayoutDescriptor = generated.BindGroupLayoutDescriptor;
pub const BindGroupLayoutEntry = generated.BindGroupLayoutEntry;
pub const BindingResource = generated.BindingResource;
pub const BlendComponent = generated.BlendComponent;
pub const BlendFactor = generated.BlendFactor;
pub const BlendOperation = generated.BlendOperation;
pub const BlendState = generated.BlendState;
pub const Buffer = generated.Buffer;
pub const BufferBindingLayout = generated.BufferBindingLayout;
pub const BufferBindingType = generated.BufferBindingType;
pub const BufferDescriptor = generated.BufferDescriptor;
pub const BufferHostMappedPointer = generated.BufferHostMappedPointer;
pub const BufferMapCallback = generated.BufferMapCallback;
pub const BufferMapCallbackInfo = generated.BufferMapCallbackInfo;
pub const BufferMapState = generated.BufferMapState;
pub const BufferUsage = generated.BufferUsage;
pub const Callback = generated.Callback;
pub const CallbackControlError = generated.CallbackControlError;
pub const CallbackMode = generated.CallbackMode;
pub const CallbackStatus = generated.CallbackStatus;
pub const Color = generated.Color;
pub const ColorSpaceDawn = generated.ColorSpaceDawn;
pub const ColorSpacePrimariesDawn = generated.ColorSpacePrimariesDawn;
pub const ColorSpaceTransferDawn = generated.ColorSpaceTransferDawn;
pub const ColorSpaceYCbCrMatrixDawn = generated.ColorSpaceYCbCrMatrixDawn;
pub const ColorSpaceYCbCrRangeDawn = generated.ColorSpaceYCbCrRangeDawn;
pub const ColorTargetState = generated.ColorTargetState;
pub const ColorTargetStateExpandResolveTextureDawn = generated.ColorTargetStateExpandResolveTextureDawn;
pub const ColorWriteMask = generated.ColorWriteMask;
pub const CommandBuffer = generated.CommandBuffer;
pub const CommandBufferDescriptor = generated.CommandBufferDescriptor;
pub const CommandEncoder = generated.CommandEncoder;
pub const CommandEncoderDescriptor = generated.CommandEncoderDescriptor;
pub const CompareFunction = generated.CompareFunction;
pub const CompatibilityModeLimits = generated.CompatibilityModeLimits;
pub const CompilationInfo = generated.CompilationInfo;
pub const CompilationInfoCallback = generated.CompilationInfoCallback;
pub const CompilationInfoCallbackInfo = generated.CompilationInfoCallbackInfo;
pub const CompilationInfoRequestStatus = generated.CompilationInfoRequestStatus;
pub const CompilationMessage = generated.CompilationMessage;
pub const CompilationMessageType = generated.CompilationMessageType;
pub const ComponentSwizzle = generated.ComponentSwizzle;
pub const CompositeAlphaMode = generated.CompositeAlphaMode;
pub const ComputePassDescriptor = generated.ComputePassDescriptor;
pub const ComputePassEncoder = generated.ComputePassEncoder;
pub const ComputePipeline = generated.ComputePipeline;
pub const ComputePipelineDescriptor = generated.ComputePipelineDescriptor;
pub const ComputeState = generated.ComputeState;
pub const ConstantEntry = generated.ConstantEntry;
pub const CopyStrideUndefined = generated.CopyStrideUndefined;
pub const CopyTextureForBrowserOptions = generated.CopyTextureForBrowserOptions;
pub const CreateComputePipelineAsyncCallback = generated.CreateComputePipelineAsyncCallback;
pub const CreateComputePipelineAsyncCallbackInfo = generated.CreateComputePipelineAsyncCallbackInfo;
pub const CreatePipelineAsyncStatus = generated.CreatePipelineAsyncStatus;
pub const CreateRenderPipelineAsyncCallback = generated.CreateRenderPipelineAsyncCallback;
pub const CreateRenderPipelineAsyncCallbackInfo = generated.CreateRenderPipelineAsyncCallbackInfo;
pub const CullMode = generated.CullMode;
pub const DawnAdapterPropertiesPowerPreference = generated.DawnAdapterPropertiesPowerPreference;
pub const DawnBufferDescriptorErrorInfoFromWireClient =
    generated.DawnBufferDescriptorErrorInfoFromWireClient;
pub const DawnCacheDeviceDescriptor = generated.DawnCacheDeviceDescriptor;
pub const DawnCompilationMessageUtf16 = generated.DawnCompilationMessageUtf16;
pub const DawnConsumeAdapterDescriptor = generated.DawnConsumeAdapterDescriptor;
pub const DawnDeviceAllocatorControl = generated.DawnDeviceAllocatorControl;
pub const DawnDrmFormatCapabilities = generated.DawnDrmFormatCapabilities;
pub const DawnDrmFormatProperties = generated.DawnDrmFormatProperties;
pub const DawnEncoderInternalUsageDescriptor = generated.DawnEncoderInternalUsageDescriptor;
pub const DawnFakeBufferOOMForTesting = generated.DawnFakeBufferOOMForTesting;
pub const DawnFakeDeviceInitializeErrorForTesting = generated.DawnFakeDeviceInitializeErrorForTesting;
pub const DawnFormatCapabilities = generated.DawnFormatCapabilities;
pub const DawnHostMappedPointerLimits = generated.DawnHostMappedPointerLimits;
pub const DawnInjectedInvalidSType = generated.DawnInjectedInvalidSType;
pub const DawnLoadCacheDataCallback = generated.DawnLoadCacheDataCallback;
pub const DawnLoadCacheDataCallbackInfo = generated.DawnLoadCacheDataCallbackInfo;
pub const DawnLoadCacheDataFunction = generated.DawnLoadCacheDataFunction;
pub const DawnRenderPassSampleCount = generated.DawnRenderPassSampleCount;
pub const DawnShaderModuleSPIRVOptionsDescriptor = generated.DawnShaderModuleSPIRVOptionsDescriptor;
pub const DawnShaderSourceSPIRV = generated.DawnShaderSourceSPIRV;
pub const DawnStoreCacheDataCallback = generated.DawnStoreCacheDataCallback;
pub const DawnStoreCacheDataCallbackInfo = generated.DawnStoreCacheDataCallbackInfo;
pub const DawnStoreCacheDataFunction = generated.DawnStoreCacheDataFunction;
pub const DawnTexelCopyBufferRowAlignmentLimits = generated.DawnTexelCopyBufferRowAlignmentLimits;
pub const DawnTextureInternalUsageDescriptor = generated.DawnTextureInternalUsageDescriptor;
pub const DawnTogglesDescriptor = generated.DawnTogglesDescriptor;
pub const DawnWGSLBlocklist = generated.DawnWGSLBlocklist;
pub const DawnWireWGSLControl = generated.DawnWireWGSLControl;
pub const DepthClearValueUndefined = generated.DepthClearValueUndefined;
pub const DepthSliceUndefined = generated.DepthSliceUndefined;
pub const DepthStencilState = generated.DepthStencilState;
pub const Device = generated.Device;
pub const DeviceDescriptor = generated.DeviceDescriptor;
pub const DeviceLostCallback = generated.DeviceLostCallback;
pub const DeviceLostCallbackInfo = generated.DeviceLostCallbackInfo;
pub const DeviceLostReason = generated.DeviceLostReason;
pub const DisposeCallback = generated.DisposeCallback;
pub const DisposeCallbackInfo = generated.DisposeCallbackInfo;
pub const EmscriptenSurfaceSourceCanvasHTMLSelector = generated.EmscriptenSurfaceSourceCanvasHTMLSelector;
pub const Error = generated.Error;
pub const ErrorFilter = generated.ErrorFilter;
pub const ErrorType = generated.ErrorType;
pub const Extent2D = generated.Extent2D;
pub const Extent3D = generated.Extent3D;
pub const ExternalTexture = generated.ExternalTexture;
pub const ExternalTextureBindingEntry = generated.ExternalTextureBindingEntry;
pub const ExternalTextureBindingLayout = generated.ExternalTextureBindingLayout;
pub const ExternalTextureDescriptor = generated.ExternalTextureDescriptor;
pub const ExternalTextureRotation = generated.ExternalTextureRotation;
pub const FeatureLevel = generated.FeatureLevel;
pub const FeatureName = generated.FeatureName;
pub const FilterMode = generated.FilterMode;
pub const FragmentState = generated.FragmentState;
pub const FrontFace = generated.FrontFace;
pub const Future = generated.Future;
pub const FutureWaitError = generated.FutureWaitError;
pub const FutureWaitInfo = generated.FutureWaitInfo;
pub const HeapProperty = generated.HeapProperty;
pub const INTERNAL_HAVE_EMDAWNWEBGPU_HEADER = generated.INTERNAL_HAVE_EMDAWNWEBGPU_HEADER;
pub const ImageCopyExternalTexture = generated.ImageCopyExternalTexture;
pub const IndexFormat = generated.IndexFormat;
pub const Instance = generated.Instance;
pub const InstanceDescriptor = generated.InstanceDescriptor;
pub const InstanceFeatureName = generated.InstanceFeatureName;
pub const InstanceLimits = generated.InstanceLimits;
pub const InvalidBinding = generated.InvalidBinding;
pub const LimitU32Undefined = generated.LimitU32Undefined;
pub const LimitU64Undefined = generated.LimitU64Undefined;
pub const Limits = generated.Limits;
pub const LoadOp = generated.LoadOp;
pub const LoggingCallback = generated.LoggingCallback;
pub const LoggingCallbackInfo = generated.LoggingCallbackInfo;
pub const LoggingType = generated.LoggingType;
pub const MapAsyncStatus = generated.MapAsyncStatus;
pub const MapMode = generated.MapMode;
pub const MemoryHeapInfo = generated.MemoryHeapInfo;
pub const MipLevelCountUndefined = generated.MipLevelCountUndefined;
pub const MipmapFilterMode = generated.MipmapFilterMode;
pub const MultisampleState = generated.MultisampleState;
pub const OptionalBool = generated.OptionalBool;
pub const Origin2D = generated.Origin2D;
pub const Origin3D = generated.Origin3D;
pub const PassTimestampWrites = generated.PassTimestampWrites;
pub const PipelineLayout = generated.PipelineLayout;
pub const PipelineLayoutDescriptor = generated.PipelineLayoutDescriptor;
pub const PipelineLayoutPixelLocalStorage = generated.PipelineLayoutPixelLocalStorage;
pub const PipelineLayoutResourceTable = generated.PipelineLayoutResourceTable;
pub const PipelineLayoutStorageAttachment = generated.PipelineLayoutStorageAttachment;
pub const PopErrorScopeCallback = generated.PopErrorScopeCallback;
pub const PopErrorScopeCallbackInfo = generated.PopErrorScopeCallbackInfo;
pub const PopErrorScopeStatus = generated.PopErrorScopeStatus;
pub const PowerPreference = generated.PowerPreference;
pub const PredefinedColorSpace = generated.PredefinedColorSpace;
pub const PresentMode = generated.PresentMode;
pub const PrimitiveState = generated.PrimitiveState;
pub const PrimitiveTopology = generated.PrimitiveTopology;
pub const Proc = generated.Proc;
pub const ProcessEventsError = generated.ProcessEventsError;
pub const QuerySet = generated.QuerySet;
pub const QuerySetDescriptor = generated.QuerySetDescriptor;
pub const QuerySetIndexUndefined = generated.QuerySetIndexUndefined;
pub const QueryType = generated.QueryType;
pub const Queue = generated.Queue;
pub const QueueDescriptor = generated.QueueDescriptor;
pub const QueueWorkDoneCallback = generated.QueueWorkDoneCallback;
pub const QueueWorkDoneCallbackInfo = generated.QueueWorkDoneCallbackInfo;
pub const QueueWorkDoneStatus = generated.QueueWorkDoneStatus;
pub const RenderBundle = generated.RenderBundle;
pub const RenderBundleDescriptor = generated.RenderBundleDescriptor;
pub const RenderBundleEncoder = generated.RenderBundleEncoder;
pub const RenderBundleEncoderDescriptor = generated.RenderBundleEncoderDescriptor;
pub const RenderBundleEncoderResourceTable = generated.RenderBundleEncoderResourceTable;
pub const RenderPassColorAttachment = generated.RenderPassColorAttachment;
pub const RenderPassDepthStencilAttachment = generated.RenderPassDepthStencilAttachment;
pub const RenderPassDescriptor = generated.RenderPassDescriptor;
pub const RenderPassDescriptorResolveRect = generated.RenderPassDescriptorResolveRect;
pub const RenderPassEncoder = generated.RenderPassEncoder;
pub const RenderPassMaxDrawCount = generated.RenderPassMaxDrawCount;
pub const RenderPassPixelLocalStorage = generated.RenderPassPixelLocalStorage;
pub const RenderPassRenderAreaRect = generated.RenderPassRenderAreaRect;
pub const RenderPassStorageAttachment = generated.RenderPassStorageAttachment;
pub const RenderPipeline = generated.RenderPipeline;
pub const RenderPipelineDescriptor = generated.RenderPipelineDescriptor;
pub const RequestAdapterCallback = generated.RequestAdapterCallback;
pub const RequestAdapterCallbackInfo = generated.RequestAdapterCallbackInfo;
pub const RequestAdapterOptions = generated.RequestAdapterOptions;
pub const RequestAdapterStatus = generated.RequestAdapterStatus;
pub const RequestAdapterWebGPUBackendOptions = generated.RequestAdapterWebGPUBackendOptions;
pub const RequestAdapterWebXROptions = generated.RequestAdapterWebXROptions;
pub const RequestDeviceCallback = generated.RequestDeviceCallback;
pub const RequestDeviceCallbackInfo = generated.RequestDeviceCallbackInfo;
pub const RequestDeviceStatus = generated.RequestDeviceStatus;
pub const ResourceTable = generated.ResourceTable;
pub const ResourceTableDescriptor = generated.ResourceTableDescriptor;
pub const SType = generated.SType;
pub const Sampler = generated.Sampler;
pub const SamplerBindingLayout = generated.SamplerBindingLayout;
pub const SamplerBindingType = generated.SamplerBindingType;
pub const SamplerDescriptor = generated.SamplerDescriptor;
pub const ShaderModule = generated.ShaderModule;
pub const ShaderModuleCompilationOptions = generated.ShaderModuleCompilationOptions;
pub const ShaderModuleDescriptor = generated.ShaderModuleDescriptor;
pub const ShaderSourceSPIRV = generated.ShaderSourceSPIRV;
pub const ShaderSourceWGSL = generated.ShaderSourceWGSL;
pub const ShaderStage = generated.ShaderStage;
pub const SharedBufferMemory = generated.SharedBufferMemory;
pub const SharedBufferMemoryBeginAccessDescriptor = generated.SharedBufferMemoryBeginAccessDescriptor;
pub const SharedBufferMemoryDescriptor = generated.SharedBufferMemoryDescriptor;
pub const SharedBufferMemoryEndAccessState = generated.SharedBufferMemoryEndAccessState;
pub const SharedBufferMemoryFromWindowsHandleDescriptor =
    generated.SharedBufferMemoryFromWindowsHandleDescriptor;
pub const SharedBufferMemoryHostPointerDescriptor = generated.SharedBufferMemoryHostPointerDescriptor;
pub const SharedBufferMemoryProperties = generated.SharedBufferMemoryProperties;
pub const SharedFence = generated.SharedFence;
pub const SharedFenceDXGISharedHandleDescriptor = generated.SharedFenceDXGISharedHandleDescriptor;
pub const SharedFenceDXGISharedHandleExportInfo = generated.SharedFenceDXGISharedHandleExportInfo;
pub const SharedFenceDescriptor = generated.SharedFenceDescriptor;
pub const SharedFenceEGLSyncDescriptor = generated.SharedFenceEGLSyncDescriptor;
pub const SharedFenceEGLSyncExportInfo = generated.SharedFenceEGLSyncExportInfo;
pub const SharedFenceExportInfo = generated.SharedFenceExportInfo;
pub const SharedFenceMTLSharedEventDescriptor = generated.SharedFenceMTLSharedEventDescriptor;
pub const SharedFenceMTLSharedEventExportInfo = generated.SharedFenceMTLSharedEventExportInfo;
pub const SharedFenceSyncFDDescriptor = generated.SharedFenceSyncFDDescriptor;
pub const SharedFenceSyncFDExportInfo = generated.SharedFenceSyncFDExportInfo;
pub const SharedFenceType = generated.SharedFenceType;
pub const SharedFenceVkSemaphoreOpaqueFDDescriptor = generated.SharedFenceVkSemaphoreOpaqueFDDescriptor;
pub const SharedFenceVkSemaphoreOpaqueFDExportInfo = generated.SharedFenceVkSemaphoreOpaqueFDExportInfo;
pub const SharedFenceVkSemaphoreZirconHandleDescriptor =
    generated.SharedFenceVkSemaphoreZirconHandleDescriptor;
pub const SharedFenceVkSemaphoreZirconHandleExportInfo =
    generated.SharedFenceVkSemaphoreZirconHandleExportInfo;
pub const SharedTextureMemory = generated.SharedTextureMemory;
pub const SharedTextureMemoryAHardwareBufferDescriptor =
    generated.SharedTextureMemoryAHardwareBufferDescriptor;
pub const SharedTextureMemoryAHardwareBufferProperties =
    generated.SharedTextureMemoryAHardwareBufferProperties;
pub const SharedTextureMemoryBeginAccessDescriptor = generated.SharedTextureMemoryBeginAccessDescriptor;
pub const SharedTextureMemoryD3D11BeginState = generated.SharedTextureMemoryD3D11BeginState;
pub const SharedTextureMemoryD3DSwapchainBeginState = generated.SharedTextureMemoryD3DSwapchainBeginState;
pub const SharedTextureMemoryDXGISharedHandleDescriptor =
    generated.SharedTextureMemoryDXGISharedHandleDescriptor;
pub const SharedTextureMemoryDescriptor = generated.SharedTextureMemoryDescriptor;
pub const SharedTextureMemoryDmaBufDescriptor = generated.SharedTextureMemoryDmaBufDescriptor;
pub const SharedTextureMemoryDmaBufPlane = generated.SharedTextureMemoryDmaBufPlane;
pub const SharedTextureMemoryEGLImageDescriptor = generated.SharedTextureMemoryEGLImageDescriptor;
pub const SharedTextureMemoryEndAccessState = generated.SharedTextureMemoryEndAccessState;
pub const SharedTextureMemoryIOSurfaceDescriptor = generated.SharedTextureMemoryIOSurfaceDescriptor;
pub const SharedTextureMemoryMetalEndAccessState = generated.SharedTextureMemoryMetalEndAccessState;
pub const SharedTextureMemoryOpaqueFDDescriptor = generated.SharedTextureMemoryOpaqueFDDescriptor;
pub const SharedTextureMemoryProperties = generated.SharedTextureMemoryProperties;
pub const SharedTextureMemoryVkDedicatedAllocationDescriptor =
    generated.SharedTextureMemoryVkDedicatedAllocationDescriptor;
pub const SharedTextureMemoryVkImageLayoutBeginState =
    generated.SharedTextureMemoryVkImageLayoutBeginState;
pub const SharedTextureMemoryVkImageLayoutEndState =
    generated.SharedTextureMemoryVkImageLayoutEndState;
pub const SharedTextureMemoryZirconHandleDescriptor = generated.SharedTextureMemoryZirconHandleDescriptor;
pub const StaticSamplerBindingLayout = generated.StaticSamplerBindingLayout;
pub const Status = generated.Status;
pub const StencilFaceState = generated.StencilFaceState;
pub const StencilOperation = generated.StencilOperation;
pub const StorageTextureAccess = generated.StorageTextureAccess;
pub const StorageTextureBindingLayout = generated.StorageTextureBindingLayout;
pub const StoreOp = generated.StoreOp;
pub const StringView = generated.StringView;
pub const Strlen = generated.Strlen;
pub const SubgroupMatrixComponentType = generated.SubgroupMatrixComponentType;
pub const SubgroupMatrixConfig = generated.SubgroupMatrixConfig;
pub const SupportedFeatures = generated.SupportedFeatures;
pub const SupportedInstanceFeatures = generated.SupportedInstanceFeatures;
pub const SupportedWGSLLanguageFeatures = generated.SupportedWGSLLanguageFeatures;
pub const Surface = generated.Surface;
pub const SurfaceCapabilities = generated.SurfaceCapabilities;
pub const SurfaceColorManagement = generated.SurfaceColorManagement;
pub const SurfaceConfiguration = generated.SurfaceConfiguration;
pub const SurfaceDescriptor = generated.SurfaceDescriptor;
pub const SurfaceDescriptorFromWindowsCoreWindow = generated.SurfaceDescriptorFromWindowsCoreWindow;
pub const SurfaceDescriptorFromWindowsUWPSwapChainPanel =
    generated.SurfaceDescriptorFromWindowsUWPSwapChainPanel;
pub const SurfaceDescriptorFromWindowsWinUISwapChainPanel =
    generated.SurfaceDescriptorFromWindowsWinUISwapChainPanel;
pub const SurfaceGetCurrentTextureStatus = generated.SurfaceGetCurrentTextureStatus;
pub const SurfaceSourceAndroidNativeWindow = generated.SurfaceSourceAndroidNativeWindow;
pub const SurfaceSourceMetalLayer = generated.SurfaceSourceMetalLayer;
pub const SurfaceSourceWaylandSurface = generated.SurfaceSourceWaylandSurface;
pub const SurfaceSourceWindowsHWND = generated.SurfaceSourceWindowsHWND;
pub const SurfaceSourceXCBWindow = generated.SurfaceSourceXCBWindow;
pub const SurfaceSourceXlibWindow = generated.SurfaceSourceXlibWindow;
pub const SurfaceTexture = generated.SurfaceTexture;
pub const TexelBufferAccess = generated.TexelBufferAccess;
pub const TexelBufferBindingEntry = generated.TexelBufferBindingEntry;
pub const TexelBufferBindingLayout = generated.TexelBufferBindingLayout;
pub const TexelBufferView = generated.TexelBufferView;
pub const TexelBufferViewDescriptor = generated.TexelBufferViewDescriptor;
pub const TexelCopyBufferInfo = generated.TexelCopyBufferInfo;
pub const TexelCopyBufferLayout = generated.TexelCopyBufferLayout;
pub const TexelCopyTextureInfo = generated.TexelCopyTextureInfo;
pub const Texture = generated.Texture;
pub const TextureAspect = generated.TextureAspect;
pub const TextureBindingLayout = generated.TextureBindingLayout;
pub const TextureBindingViewDimension = generated.TextureBindingViewDimension;
pub const TextureComponentSwizzle = generated.TextureComponentSwizzle;
pub const TextureComponentSwizzleDescriptor = generated.TextureComponentSwizzleDescriptor;
pub const TextureDescriptor = generated.TextureDescriptor;
pub const TextureDimension = generated.TextureDimension;
pub const TextureFormat = generated.TextureFormat;
pub const TextureSampleType = generated.TextureSampleType;
pub const TextureUsage = generated.TextureUsage;
pub const TextureView = generated.TextureView;
pub const TextureViewDescriptor = generated.TextureViewDescriptor;
pub const TextureViewDimension = generated.TextureViewDimension;
pub const ToneMappingMode = generated.ToneMappingMode;
pub const UncapturedErrorCallback = generated.UncapturedErrorCallback;
pub const UncapturedErrorCallbackInfo = generated.UncapturedErrorCallbackInfo;
pub const VertexAttribute = generated.VertexAttribute;
pub const VertexBufferLayout = generated.VertexBufferLayout;
pub const VertexFormat = generated.VertexFormat;
pub const VertexState = generated.VertexState;
pub const VertexStepMode = generated.VertexStepMode;
pub const WGSLLanguageFeatureName = generated.WGSLLanguageFeatureName;
pub const WaitStatus = generated.WaitStatus;
pub const WholeMapSize = generated.WholeMapSize;
pub const WholeSize = generated.WholeSize;
pub const YCbCrVkDescriptor = generated.YCbCrVkDescriptor;
pub const bitmask = generated.bitmask;
pub const callbacks = generated.callbacks;
pub const chained = generated.chained;
pub const constants = generated.constants;
pub const createInstance = generated.createInstance;
pub const descriptors = generated.descriptors;
pub const enums = generated.enums;
pub const errors = generated.errors;
pub const getInstanceFeatures = generated.getInstanceFeatures;
pub const getInstanceLimits = generated.getInstanceLimits;
pub const getProcAddress = generated.getProcAddress;
pub const handled = generated.handled;
pub const hasInstanceFeature = generated.hasInstanceFeature;
pub const natives = generated.natives;
pub const objects = generated.objects;
pub const proc = generated.proc;
