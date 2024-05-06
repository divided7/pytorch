#define TORCH_ASSERT_NO_OPERATORS
#include <ATen/native/cuda/Sort.h> // 在CUDA环境中执行排序相关操作的函数和类的声明。这可能包括排序算法的实现，CUDA内核的启动以及与排序相关的辅助函数。
#include <ATen/core/TensorBase.h> // 关于张量基类 TensorBase 的声明。基类通常包含了所有张量都共享的基本功能和属性。
#include <ATen/core/Array.h> // 关于数组类的声明，可能定义了一些在CUDA环境中处理数组数据的基本操作和工具函数。
#include <ATen/Dispatch.h> // 关于分发机制的声明，分发机制用于根据输入参数的类型和属性选择合适的实现代码。在CUDA环境中，这可能涉及到根据不同的硬件架构和数据类型选择合适的CUDA内核。
#include <ATen/cuda/cub.cuh> // 与CUB（CUDA Unbound）库相关的声明，CUB是一个用于CUDA编程的开源C++模板库，提供了高效的并行算法和数据结构。
#include <ATen/cuda/CUDAContext.h> // 与CUDA上下文管理相关的声明，包括初始化CUDA设备，分配和释放CUDA内存等功能。
#include <ATen/cuda/detail/KernelUtils.h> // 一些CUDA内核编程中常用的实用工具函数和宏定义，用于简化内核代码的编写和优化。
#include <ATen/cuda/detail/OffsetCalculator.cuh> // 包含了用于计算CUDA内核中数据偏移量的工具函数和类的声明，这在处理多维数组时非常有用。
#include <ATen/cuda/NumericLimits.cuh> // 包含了CUDA环境中数值限制的声明，例如最大值、最小值等。
#include <ATen/native/cuda/SortUtils.cuh> // 一些在CUDA环境中执行排序操作时所需的辅助函数和工具类的声明。
#include <ATen/native/cuda/SortingCommon.cuh> // 在CUDA环境中执行排序时共享的一些常量、数据结构和算法。

#include <limits> // C++ 标准库中的头文件，其中包含了一些关于数值范围的常量和函数。被用来获取数据类型的最大值、最小值等信息。
#include <c10/core/DeviceArray.h> // 包含了与 DeviceArray 类相关的声明。DeviceArray 是 PyTorch 中的一个类，用于在不同的设备上管理数据的数组。它可能提供了在 CUDA 设备上分配、释放和管理内存的方法，以及对数组数据进行操作的接口。

namespace at::native { // 这是一个命名空间声明，指定了一系列与 PyTorch 相关的本地（native）函数

template <typename T> // 这是一个模板函数的声明，T 是一个占位符，表示函数可以接受不同类型的参数。这意味着函数 minimum_grid_for_occupancy 可以接受不同类型的 kernel 参数。
static int minimum_grid_for_occupancy(T kernel, int max_block_size) {  // minimum_grid_for_occupancy函数开始
  int minGridSize = 0;
  int blockSize;
  C10_CUDA_CHECK(cudaOccupancyMaxPotentialBlockSize(
      &minGridSize,
      &blockSize,
      kernel,
      /*dynamicSMemSize=*/0,
      max_block_size));
  return minGridSize;
} // 计算 CUDA 核函数执行时所需的最小网格大小，并返回这个值。这个值可以用于在 CUDA 加速的环境中配置执行核函数的线程块和网格

template <typename T> 
constexpr bool has_nan() {  // 定义了一个模板函数 has_nan()，用于检查给定类型 T 是否支持 NaN（Not a Number）。
  if constexpr (std::numeric_limits<T>::is_specialized) {
    return std::numeric_limits<T>::has_quiet_NaN;
  } else if constexpr (
      c10::is_complex<T>::value ||
      std::is_same_v<T, c10::BFloat16> ||
      std::is_same_v<T, c10::Half>) {
    return true;
  }
} // 这段代码用于在编译时确定给定类型 T 是否支持 NaN，如果支持 NaN，则返回 true，否则返回 false。


// For very small unstable sorts (n <= 32), use bitonicSortKVInPlace
// which can sort multiple arrays within the same block of threads,
// improving occupancy.
// 对于非常小的数据集（元素个数小于或等于 32）, 使用 bitonicSortKVInPlace 函数。
// 该函数可以在同一块线程内对多个数组进行排序。
// 这意味着可以在 GPU 中的一个线程块中同时对多个数组进行排序，而不是每个数组单独排序，从而提高了 GPU 的利用率和性能。

struct SmallBitonicSort { // 定义了一个 SmallBitonicSort 结构体，其中包含一个模板成员函数 sort()，用于在 CUDA 环境中执行针对非常小的数据集的比特分组排序（bitonic sort）。
  template <int A, typename K, typename V, typename IndexType>
  void sort(
      at::cuda::detail::TensorInfo<K, IndexType> keyInfo,
      IndexType keySlices,
      IndexType keySliceSize,
      IndexType keySliceStride,
      at::cuda::detail::TensorInfo<V, IndexType> valueInfo,
      IndexType valueSliceStride,
      bool descending) {
    constexpr int sort_size = 32;
    constexpr int max_block_y = 16;
    constexpr int items_per_thread = 2;
    static_assert(sort_size % items_per_thread == 0, "");
    constexpr int block_x = sort_size / items_per_thread;

    TORCH_INTERNAL_ASSERT(keySliceSize <= sort_size);

    // Scale batch size down if the grid would be too small
    const auto min_grid = minimum_grid_for_occupancy(
        bitonicSortKVInPlace<
            A, -1, block_x, max_block_y,
            K, V, LTOp<K, true>, IndexType>,
        block_x * max_block_y);
    const auto max_batch = std::max(IndexType{1}, keySlices / min_grid);
    const int block_y = std::min(IndexType(max_block_y), max_batch);
    dim3 block(block_x, block_y);

    dim3 grid;
    const int grid_count = (keySlices + block_y - 1) / block_y;
    TORCH_INTERNAL_ASSERT(getGridFromTiles(grid_count, grid),
                          "Too many slices to sort");
    const auto stream = at::cuda::getCurrentCUDAStream();

    if (descending) {
      bitonicSortKVInPlace<A, -1, block_x, max_block_y>
        <<<grid, block, 0, stream>>>(
          keyInfo,
          keySlices,
          keySliceSize,
          keySliceStride,
          valueInfo,
          valueSliceStride,
          GTOp<K, true>());
      C10_CUDA_KERNEL_LAUNCH_CHECK();
    } else {
      bitonicSortKVInPlace<A, -1, block_x, max_block_y>
        <<<grid, block, 0, stream>>>(
          keyInfo,
          keySlices,
          keySliceSize,
          keySliceStride,
          valueInfo,
          valueSliceStride,
          LTOp<K, true>());
      C10_CUDA_KERNEL_LAUNCH_CHECK();
    }
  }
};

#if HAS_WARP_MERGE_SORT()

// For small sorts (n <= 128) we use warpMergeSortKVInPlace which
// sorts one slice per warp and potentially multiple slices in the
// same block for improved occupancy with large batch sizes.
template <int sort_size>
struct WarpMergeSort {

  template <int A, typename K, typename V, typename IndexType>
  void sort(
      at::cuda::detail::TensorInfo<K, IndexType> keyInfo,
      IndexType keySlices,
      IndexType keySliceSize,
      IndexType keySliceStride,
      at::cuda::detail::TensorInfo<V, IndexType> valueInfo,
      IndexType valueSliceStride,
      bool descending) {
    constexpr int max_block_y = 16;
    const int block_x = at::cuda::warp_size();

    TORCH_INTERNAL_ASSERT(keySliceSize <= sort_size);

    // Scale batch size down if the grid would be too small
    const auto min_grid = minimum_grid_for_occupancy(
        warpMergeSortKVInPlace<
            A, -1, sort_size, max_block_y,
            K, V, LTOp<K, true>, IndexType>,
        block_x * max_block_y);
    const auto max_batch = std::max(IndexType{1}, keySlices / min_grid);
    const int block_y = std::min(IndexType(max_block_y), max_batch);
    dim3 block(block_x, block_y);

    dim3 grid;
    const int grid_count = (keySlices + block_y - 1) / block_y;
    TORCH_INTERNAL_ASSERT(getGridFromTiles(grid_count, grid),
                          "Too many slices to sort");
    const auto stream = at::cuda::getCurrentCUDAStream();

    if (descending) {
      const K invalid_key = at::numeric_limits<K>::lower_bound();
      warpMergeSortKVInPlace<A, -1, sort_size, max_block_y>
        <<<grid, block, 0, stream>>>(
          keyInfo,
          keySlices,
          keySliceSize,
          keySliceStride,
          valueInfo,
          valueSliceStride,
          GTOp<K, true>(),
          invalid_key);
      C10_CUDA_KERNEL_LAUNCH_CHECK();
    } else {
      const K invalid_key = []{
        // NAN is sorted after inf
        if constexpr(has_nan<K>()) {
          return K(NAN);
        }
        return at::numeric_limits<K>::upper_bound();
      }();
      warpMergeSortKVInPlace<A, -1, sort_size, max_block_y>
        <<<grid, block, 0, stream>>>(
          keyInfo,
          keySlices,
          keySliceSize,
          keySliceStride,
          valueInfo,
          valueSliceStride,
          LTOp<K, true>(),
          invalid_key);
      C10_CUDA_KERNEL_LAUNCH_CHECK();
    }
  }
};

#endif // !HAS_WARP_MERGE_SORT()

// For medium sizes (128 < n <= 4096) use radixSortKVInplace.
struct MediumRadixSort {

  template <int A, typename K, typename V, typename IndexType>
  void sort(
      at::cuda::detail::TensorInfo<K, IndexType> keyInfo,
      IndexType keySlices,
      IndexType keySliceSize,
      IndexType keySliceStride,
      at::cuda::detail::TensorInfo<V, IndexType> valueInfo,
      IndexType valueSliceStride,
      bool descending) {

#define HANDLE_CASE(SIZE, ITEMS_PER_THREAD)         \
    fixed_size_sort<A, SIZE, ITEMS_PER_THREAD>(     \
        keyInfo,                                    \
        keySlices,                                  \
        keySliceSize,                               \
        keySliceStride,                             \
        valueInfo,                                  \
        valueSliceStride,                           \
        descending)

    int64_t ceilPowerOf2 = nextHighestPowerOf2(keySliceSize);
    TORCH_INTERNAL_ASSERT(ceilPowerOf2 <= 4096);
    switch (ceilPowerOf2) {
      case 4096:
        HANDLE_CASE(4096, 32);
        break;
      case 2048:
        HANDLE_CASE(2048, 32);
        break;
      case 1024:
      case 512:
      case 256:
        HANDLE_CASE(1024, 32);
        break;
      case 128:
      case 64:
#if !HAS_WARP_MERGE_SORT()
        HANDLE_CASE(128, 4);
        break;
#endif
      case 32:
      case 16:
      case 8:
      case 4:
      case 2:
#if HAS_WARP_MERGE_SORT()
        TORCH_INTERNAL_ASSERT(
            false, "Expected size <= 128 to be handled by a different algorithm");
#else
        HANDLE_CASE(32, 2);
#endif
        break;
      case 1:
        /* Nothing to do, data already sorted */
        break;
      default:
        TORCH_INTERNAL_ASSERT(false);
    }
#undef HANDLE_CASE

  }

  template <int A, int sort_size, int items_per_thread,
            typename K, typename V, typename IndexType>
  void fixed_size_sort(
      at::cuda::detail::TensorInfo<K, IndexType> keyInfo,
      IndexType keySlices,
      IndexType keySliceSize,
      IndexType keySliceStride,
      at::cuda::detail::TensorInfo<V, IndexType> valueInfo,
      IndexType valueSliceStride,
      bool descending) {
    static_assert(sort_size % items_per_thread == 0, "");
    constexpr int block = sort_size / items_per_thread;
    dim3 grid;
    TORCH_INTERNAL_ASSERT(getGridFromTiles(keySlices, grid),
                          "Too many slices to sort");

    const auto stream = at::cuda::getCurrentCUDAStream();
    radixSortKVInPlace<A, -1, block, items_per_thread>
        <<<grid, block, 0, stream>>>(
          keyInfo,
          keySlices,
          keySliceSize,
          keySliceStride,
          valueInfo,
          valueSliceStride,
          descending);
    C10_CUDA_KERNEL_LAUNCH_CHECK();
  }
};

template <typename Sorter>
void sortCommon(Sorter sorter, const TensorBase &key, const TensorBase &value,
                int dim, bool descending) {
  TORCH_CHECK(key.sizes() == value.sizes(),
              "Key tensor must have same size as value tensor");
  int dims = value.dim();
  TORCH_CHECK(dims <= MAX_DIMS, "value tensor has too many dimensions");
  // if key and value tensors have the same size, we do not need to check both

  ptrdiff_t inElements = key.numel();

  if (inElements == 0) {
    return;
  }

  int64_t keySliceSize = key.size(dim);
  ptrdiff_t keySlices = inElements / keySliceSize;

#define HANDLE_SORT_CASE(TYPE, A)                   \
  sorter.template sort<A>(                          \
      keyInfo,                                      \
      (TYPE) keySlices,                             \
      (TYPE) keySliceSize,                          \
      (TYPE) keyInfo.strides[collapseKeyDim],       \
      valueInfo,                                    \
      (TYPE) valueInfo.strides[collapseValueDim],   \
      descending)

  // The constructed key/value tensor info is used to select the slice
  // we are sorting on a per-block basis
  // The constructed key/value tensor info is used to select the slice
  // we are sorting on a per-block basis
  AT_DISPATCH_ALL_TYPES_AND3(at::ScalarType::Half, at::ScalarType::BFloat16, at::ScalarType::Bool, key.scalar_type(), "sortKeyValueInplace", [&]  {
    if (at::cuda::detail::canUse32BitIndexMath(key)) {
      at::cuda::detail::TensorInfo<scalar_t, unsigned int> keyInfo =
        at::cuda::detail::getTensorInfo<scalar_t, unsigned int>(key);
      at::cuda::detail::TensorInfo<int64_t, unsigned int> valueInfo =
        at::cuda::detail::getTensorInfo<int64_t, unsigned int>(value);

      auto strideKey = keyInfo.strides[dim];
      keyInfo.sizes[dim] = 1;
      int collapseKeyDim = keyInfo.collapseDims(dim);
      keyInfo.strides[collapseKeyDim] = strideKey;
      auto strideValue = valueInfo.strides[dim];
      valueInfo.sizes[dim]=1;
      int collapseValueDim = valueInfo.collapseDims(dim);
      valueInfo.strides[collapseValueDim] = strideValue;

      if (keyInfo.isContiguous()) {
        HANDLE_SORT_CASE(unsigned int, -2);
      } else {
        switch (keyInfo.dims) {
          case 2:
            HANDLE_SORT_CASE(unsigned int, 2);
            break;
          default:
            HANDLE_SORT_CASE(unsigned int, -1);
            break;
        }
      }

    } else {
      at::cuda::detail::TensorInfo<scalar_t, uint64_t> keyInfo =
        at::cuda::detail::getTensorInfo<scalar_t, uint64_t>(key);
      at::cuda::detail::TensorInfo<int64_t, uint64_t> valueInfo =
        at::cuda::detail::getTensorInfo<int64_t, uint64_t>(value);

      auto strideKey = keyInfo.strides[dim];
      keyInfo.sizes[dim] = 1;
      int collapseKeyDim = keyInfo.collapseDims(dim);
      keyInfo.strides[collapseKeyDim] = strideKey;
      auto strideValue = valueInfo.strides[dim];
      valueInfo.sizes[dim]=1;
      int collapseValueDim = valueInfo.collapseDims(dim);
      valueInfo.strides[collapseValueDim] = strideValue;

      // int64_t case is rare, just instantiate the generic version
      HANDLE_SORT_CASE(uint64_t, -1);
    }
  });
#undef HANDLE_SORT_CASE
}

void sortKeyValueInplace(
    const TensorBase& key,
    const TensorBase& value,
    int dim,
    bool descending,
    bool stable) {
  const auto sort_size = key.size(dim);
  if (sort_size <= 1) {
    return; // Already sorted
  } else if (!stable && sort_size <= 32) {
    // NOTE: Bitonic sort is unstable
    sortCommon(SmallBitonicSort{}, key, value, dim, descending);
#if HAS_WARP_MERGE_SORT()
  } else if (sort_size <= 128) {
    sortCommon(WarpMergeSort<128>{}, key, value, dim, descending);
#endif
  } else {
    sortCommon(MediumRadixSort{}, key, value, dim, descending);
  }
}

}  // namespace at::native
