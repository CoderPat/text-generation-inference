import os
import torch

from loguru import logger

if os.getenv("USE_FLASH_ATTENTION", "").lower() == "false":
    raise ImportError("`USE_FLASH_ATTENTION` is false.")

if not torch.cuda.is_available():
    raise ImportError("CUDA is not available")

major, minor = torch.cuda.get_device_capability()
is_sm75 = major == 7 and minor == 5
is_sm8x = major == 8 and minor >= 0
is_sm90 = major == 9 and minor == 0

HAS_FLASH_ATTN = False
try:
    import flash_attn_2_cuda as flash_attn_cuda
except ImportError as e:
    raise ImportError(
        f"Flash Attention V2 is not installed.\n"
        f"Error message: {e}\n"
        "Use the official Docker image (ghcr.io/huggingface/text-generation-inference:latest) "
        "or install flash attention v2 with `cd server && make install install-flash-attention-v2`"
    )
if not (is_sm8x or is_sm90):
    raise ImportError(
        f"GPU with CUDA capability {major} {minor} is not supported for "
        "Flash Attention V2"
    )

def attention(
    q,
    k,
    v,
    out,
    cu_seqlens,
    max_s,
    softmax_scale,
):
    if HAS_FLASH_ATTN:
        return flash_attn_cuda.varlen_fwd(
            q,
            k,
            v,
            out,
            cu_seqlens,
            cu_seqlens,
            max_s,
            max_s,
            0.0,
            softmax_scale,
            False,
            True,
            False,
            None,
        )

    raise NotImplementedError("flash attention is not installed")
