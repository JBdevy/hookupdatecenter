#!/usr/bin/env python3
"""Generate HTDemucs6's exact spectral boundary without loading any weights."""
import math
from pathlib import Path
import sys
import torch
from torch.nn import functional as F

torch.set_num_threads(1)
torch.manual_seed(851)
destination = Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
length, nfft, hop = 44100, 4096, 1024
frames = math.ceil(length / hop)
window = torch.hann_window(nfft)
time = torch.arange(length) / length
pcm = torch.stack((0.2 * torch.sin(2 * torch.pi * (317 * time + 600 * time.square())),
                   0.17 * torch.cos(2 * torch.pi * 1800 * time)))
pcm += torch.randn_like(pcm) * 0.013
pcm[:, [0, 1536, 2048, 8192, length - 1]] += 0.4
padded = F.pad(pcm.unsqueeze(0), (1536, 1536 + frames * hop - length), mode="reflect")[0]
complex_spectrum = torch.stft(padded, nfft, hop, window=window, normalized=True,
                              center=True, return_complex=True, pad_mode="reflect")[:, :-1, 2:2 + frames]
spectrum = torch.view_as_real(complex_spectrum).permute(0, 3, 1, 2).reshape(4, 2048, frames)


def decode(cac):
    values = cac.reshape(2, 2, 2048, frames).permute(0, 2, 3, 1).contiguous()
    values = torch.view_as_complex(values)
    values = F.pad(values, (0, 0, 0, 1))
    values = F.pad(values, (2, 2))
    result = torch.istft(values, nfft, hop, window=window, normalized=True,
                        center=True, length=hop * frames + 3072)
    return result[:, 1536:1536 + length]


predicted = spectrum * 0.8 + torch.randn_like(spectrum) * 0.1
for name, tensor in (("input", pcm), ("spectrum", spectrum),
                     ("reconstructed", decode(spectrum)), ("predicted", predicted),
                     ("prediction-audio", decode(predicted))):
    tensor.contiguous().numpy().astype("<f4").tofile(destination / (name + ".f32"))
print("Created deterministic HTDemucs6 STFT/ISTFT reference fixtures.")
