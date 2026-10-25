#!/usr/bin/env python3
"""Offline HTDemucs6 FP32 graph with the original 7.8-second model context."""
from __future__ import annotations
import argparse
from fractions import Fraction
import importlib.util
import json
import os
from pathlib import Path
import tempfile

# The helper is loaded by absolute path because the isolated Python worker uses -I.
spec = importlib.util.spec_from_file_location("catstem_offline_shared", Path(__file__).with_name("openvino_backend.py"))
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)
np, torch, ov = shared.np, shared.torch, shared.ov
RATE = 44100
CONTEXT = 343980
SEGMENT = Fraction(39, 5)
MODEL_FILE = "htdemucs6-offline.xml"
MANIFEST_FILE = "htdemucs6-offline.json"
FORMAT_VERSION = 1
FILES = (MODEL_FILE, Path(MODEL_FILE).with_suffix(".bin").name)


def verified_manifest(directory):
    directory = Path(directory)
    manifest = json.loads((directory / MANIFEST_FILE).read_text(encoding="utf-8"))
    expected = {"formatVersion": FORMAT_VERSION, "sourceCheckpointSHA": shared.SOURCE_SHA,
                "contextFrames": CONTEXT, "sampleRate": RATE, "sources": shared.SOURCES,
                "precision": "f32", "nfft": 4096, "hopLength": 1024,
                "graphOptimizations": shared.GRAPH_OPTIMIZATIONS}
    if any(manifest.get(key) != value for key, value in expected.items()):
        raise ValueError("The offline CatStem model has an incompatible identity or configuration")
    for name in FILES:
        if shared.digest(directory / name) != manifest.get("files", {}).get(name):
            raise ValueError("Offline CatStem model SHA256 mismatch: " + name)
    return manifest


class OfflineOpenVINOModel(torch.nn.Module):
    """Demucs apply_model-compatible wrapper; its chunking and blending stay intact."""
    def __init__(self, model_path, device="CPU", precision="f32"):
        super().__init__()
        model_path = Path(model_path)
        if shared.digest(model_path) != shared.SOURCE_SHA:
            raise ValueError("CatStem source checkpoint SHA256 mismatch")
        manifest = verified_manifest(model_path.parent)
        self.segment = SEGMENT
        self.samplerate = RATE
        self.sources = list(shared.SOURCES)
        self.audio_channels = 2
        self.device_name = device.upper()
        if self.device_name not in ("CPU", "GPU"):
            raise ValueError("Offline CatStem requires CPU or Intel GPU")
        if precision != "f32":
            raise ValueError("Offline CatStem inference requires FP32 precision")
        self.inference_precision = precision
        shared.configure_torch(1 if self.device_name == "GPU" else None)
        self.spectral = shared.SpectralTransform(manifest["nfft"], manifest["hopLength"])
        local = Path(os.environ.get("LOCALAPPDATA", str(Path.home() / "AppData/Local")))
        cache = (local / "Hook Developer/CatLive/Cache/CatStemOffline" / manifest["files"][MODEL_FILE]
                 / self.device_name / precision)
        cache.mkdir(parents=True, exist_ok=True)
        options = {"PERFORMANCE_HINT": "LATENCY", "INFERENCE_PRECISION_HINT": precision, "CACHE_DIR": str(cache)}
        if self.device_name == "CPU":
            options["INFERENCE_NUM_THREADS"] = max(1, min(8, (os.cpu_count() or 2) - 2))
        else:
            options["GPU_QUEUE_THROTTLE"] = "LOW"
        self.core = ov.Core()
        self.compiled = self.core.compile_model(str(model_path.parent / MODEL_FILE), self.device_name, options)
        self.request = self.compiled.create_infer_request()

    def valid_length(self, length):
        if not 0 < length <= CONTEXT:
            raise ValueError("Invalid offline CatStem context length")
        return CONTEXT

    def forward(self, mix):
        if tuple(mix.shape) != (1, 2, CONTEXT) or mix.device.type != "cpu" or mix.dtype != torch.float32:
            raise ValueError("Offline CatStem needs one full stereo FP32 context on CPU")
        with torch.inference_mode():
            magnitude = self.spectral.encode(mix)
            values = self.request.infer({0: mix.numpy(), 1: magnitude.numpy()}, share_inputs=True, share_outputs=True)
            frequency = torch.from_numpy(values[self.compiled.output(0)])
            temporal = torch.from_numpy(values[self.compiled.output(1)])
            result = self.spectral.decode(frequency, temporal, CONTEXT)
        if tuple(result.shape) != (1, 6, 2, CONTEXT) or not torch.isfinite(result).all():
            raise ValueError("Offline CatStem returned malformed or nonfinite audio")
        return result


def convert_model(model_path, output_directory):
    from demucs.states import load_model
    model_path, directory = Path(model_path), Path(output_directory)
    if shared.digest(model_path) != shared.SOURCE_SHA:
        raise ValueError("CatStem source checkpoint SHA256 mismatch")
    shared.configure_torch()
    original = load_model(model_path).eval()
    if (list(original.sources) != shared.SOURCES or original.samplerate != RATE or not original.cac
            or int(original.segment * RATE) != CONTEXT):
        raise ValueError("Unexpected offline CatStem model contract")
    network = shared.NetworkCore(original).eval()
    spectral = shared.SpectralTransform(original.nfft, original.hop_length)
    generator = np.random.default_rng(19)
    time = np.arange(CONTEXT, dtype=np.float32) / RATE
    harmonic = np.stack((.1 * np.sin(time * 440 * 2 * np.pi), .07 * np.sin(time * 660 * 2 * np.pi)))[None]
    harmonic[:, :, ::4096] += .2
    fixtures = [generator.normal(0, .03, (1, 2, CONTEXT)).astype(np.float32), harmonic.astype(np.float32),
                generator.normal(0, .0001, (1, 2, CONTEXT)).astype(np.float32)]
    example = torch.from_numpy(fixtures[0])
    with torch.inference_mode():
        magnitude = spectral.encode(example)
        if not torch.equal(magnitude, original._magnitude(original._spec(example))):
            raise RuntimeError("Offline CatStem spectral encoding differs from the checkpoint")
        frequency, temporal = network(example, magnitude)
        reference = original(example)
        split_error = float((spectral.decode(frequency, temporal, CONTEXT) - reference).abs().max())
        if split_error > 1e-6:
            raise RuntimeError("Offline CatStem split graph differs from the checkpoint")
        traced = torch.jit.trace(network, (example, magnitude), check_trace=False, strict=False)
    converted = ov.convert_model(traced, input=[list(example.shape), list(magnitude.shape)])
    counts = shared.optimize_network_graph(converted)
    core = ov.Core()
    compiled = core.compile_model(converted, "CPU", {"PERFORMANCE_HINT": "LATENCY",
        "INFERENCE_PRECISION_HINT": "f32", "INFERENCE_NUM_THREADS": max(1, min(8, os.cpu_count() or 1))})
    request = compiled.create_infer_request()
    checks = []
    for fixture in fixtures:
        pcm = torch.from_numpy(fixture)
        with torch.inference_mode():
            reference = original(pcm).numpy()
            magnitude = spectral.encode(pcm)
            values = request.infer({0: fixture, 1: magnitude.numpy()}, share_inputs=True, share_outputs=True)
            frequency = torch.from_numpy(values[compiled.output(0)])
            temporal = torch.from_numpy(values[compiled.output(1)])
            predicted = spectral.decode(frequency, temporal, CONTEXT).numpy()
        if not np.isfinite(predicted).all():
            raise RuntimeError("Offline CatStem conversion returned nonfinite audio")
        per_source = []
        for source, label in enumerate(shared.SOURCES):
            delta = (predicted[:, source] - reference[:, source]).astype(np.float64)
            expected = reference[:, source].astype(np.float64)
            maximum = float(np.abs(delta).max())
            relative = float(np.sqrt(np.mean(delta ** 2)) / max(1e-12, np.sqrt(np.mean(expected ** 2))))
            if maximum > 2e-5 or relative > .001:
                raise RuntimeError(f"Offline CatStem FP32 conversion changed source {label}: max={maximum}, relative RMS={relative}")
            per_source.append({"source": label, "maximumAbsoluteError": maximum, "relativeRMSError": relative})
        checks.append({"perSource": per_source})
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="catstem-offline-ir-", dir=directory) as temporary:
        temporary = Path(temporary)
        ov.save_model(converted, str(temporary / MODEL_FILE), compress_to_fp16=False)
        files = {name: shared.digest(temporary / name) for name in FILES}
        manifest = {"formatVersion": FORMAT_VERSION, "sourceCheckpointSHA": shared.SOURCE_SHA,
            "sampleRate": RATE, "contextFrames": CONTEXT, "sources": shared.SOURCES, "precision": "f32",
            "graphOptimizations": shared.GRAPH_OPTIMIZATIONS, "optimizationCounts": counts,
            "nfft": original.nfft, "hopLength": original.hop_length, "openvino": ov.__version__,
            "torch": torch.__version__, "files": files, "validation": checks, "splitGraphMaximumError": split_error}
        for name in FILES:
            (temporary / name).replace(directory / name)
        (temporary / MANIFEST_FILE).write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        (temporary / MANIFEST_FILE).replace(directory / MANIFEST_FILE)
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify", action="store_true")
    args = parser.parse_args()
    if args.verify:
        if shared.digest(args.model) != shared.SOURCE_SHA:
            raise ValueError("CatStem source checkpoint SHA256 mismatch")
        result = verified_manifest(args.output)
    else:
        result = convert_model(args.model, args.output)
    print(json.dumps(result, allow_nan=False))
