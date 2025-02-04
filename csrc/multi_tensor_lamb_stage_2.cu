#include <ATen/ATen.h>
#include <ATen/AccumulateType.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/Exceptions.h>
// Another possibility:
// #include <torch/all.h>

#include <assert.h>

#include "type_shim.h"
#include "multi_tensor_apply.cuh"

#define BLOCK_SIZE 512
#define ILP 4

// Step 2 reads in 'update' value and per-tensor param_norm and update_norm.
// It computes new parameter value.
template<typename T>
struct LAMBStage2Functor
{
   __device__ __forceinline__ void operator()(
    int chunk_size,
    volatile int* noop_gmem,
    TensorListMetadata<2>& tl,
    const float* per_tensor_param_norm,
    const float* per_tensor_update_norm,
    const float learning_rate)
  {
    // I'd like this kernel to propagate infs/nans.
    // if(*noop_gmem == 1)
    //   return;

    int tensor_loc = tl.block_to_tensor[blockIdx.x];
    int tensor_num = tl.start_tensor_this_launch + tensor_loc;
    int chunk_idx = tl.block_to_chunk[blockIdx.x];
    int n = tl.sizes[tensor_loc];

    float param_norm = per_tensor_param_norm[tensor_num];
    float update_norm = per_tensor_update_norm[tensor_num];
    T ratio = (update_norm != 0.0f && param_norm != 0.0f) ? learning_rate * (param_norm / update_norm) : learning_rate;

    T* p = (T*)tl.addresses[0][tensor_loc];
    p += chunk_idx*chunk_size;

    T* update = (T*)tl.addresses[1][tensor_loc];
    update += chunk_idx*chunk_size;

    n -= chunk_idx*chunk_size;

    for(int i_start = 0;
            i_start < n && i_start < chunk_size;
            i_start += blockDim.x*ILP)
    {
      // see note in multi_tensor_scale_kernel.cu
#pragma unroll
      for(int ii = 0; ii < ILP; ii++)
      {
        int i = i_start + threadIdx.x + ii*blockDim.x;
        if(i < n && i < chunk_size)
        {
          p[i] = p[i] - (ratio*update[i]);
        }
      }
    }
  }
};

void multi_tensor_lamb_stage2_cuda(
  int chunk_size,
  at::Tensor noop_flag,
  std::vector<std::vector<at::Tensor>> tensor_lists,
  at::Tensor per_tensor_param_norm,
  at::Tensor per_tensor_update_norm,
  const float learning_rate)
{
  using namespace at;

  DISPATCH_FLOAT_AND_HALF(tensor_lists[0][0].scalar_type(), 0, "lamb_stage_2",
      multi_tensor_apply<2>(
        BLOCK_SIZE,
        chunk_size,
        noop_flag,
        tensor_lists,
        LAMBStage2Functor<scalar_t_0>(),
        per_tensor_param_norm.data<float>(),
        per_tensor_update_norm.data<float>(),
        learning_rate); )

  AT_CUDA_CHECK(cudaGetLastError());

  // AT_CUDA_CHECK(cudaDeviceSynchronize());
}
