// ==================================================================================
// Copyright (c) 2017 HiFi-LoFi
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is furnished
// to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
// WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
// ==================================================================================

#include "FFTConvolver.h"

#include <cassert>
#include <cmath>

#if defined (FFTCONVOLVER_USE_SSE)
  #include <xmmintrin.h>
#endif


namespace fftconvolver
{

FFTConvolver::FFTConvolver() :
  _blockSize(0),
  _segSize(0),
  _segCount(0),
  _fftComplexSize(0),
  _segments(),
  _segmentsIR(),
  _segmentGeneration(),
  _generation(1),
  _fftBuffer(),
  _fft(),
  _preMultiplied(),
  _conv(),
  _overlap(),
  _current(0),
  _inputBuffer(),
  _inputBufferFill(0),
  _steppedPending(false),
  _stepNext(0),
  _stepFftPosition(0)
{
}


FFTConvolver::~FFTConvolver()
{
  reset();
}


void FFTConvolver::reset()
{
  for (size_t i=0; i<_segCount; ++i)
  {
    delete _segments[i];
    delete _segmentsIR[i];
  }

  _blockSize = 0;
  _segSize = 0;
  _segCount = 0;
  _fftComplexSize = 0;
  _segments.clear();
  _segmentsIR.clear();
  _segmentGeneration.clear();
  _generation = 1;
  _fftBuffer.clear();
  _fft.init(0);
  _preMultiplied.clear();
  _conv.clear();
  _overlap.clear();
  _current = 0;
  _inputBuffer.clear();
  _inputBufferFill = 0;
  _steppedPending = false;
  _stepNext = 0;
}


void FFTConvolver::clearHistory()
{
  // Hook Keys: zerar os espectros de um Hall (megabytes) travava o callback
  // no panic e ao religar o reverb. Uma geracao nova faz cada espectro antigo
  // valer silencio; so os buffers que voltam a ser somados sao zerados.
  // _fftBuffer, _preMultiplied e _conv sao reescritos antes de qualquer leitura.
  if (++_generation == 0)
  {
    std::fill(_segmentGeneration.begin(), _segmentGeneration.end(), 0u);
    _generation = 1;
  }
  _overlap.setZero();
  _inputBuffer.setZero();
  _current = 0;
  _inputBufferFill = 0;
  _steppedPending = false;
  _stepNext = 0;
}


bool FFTConvolver::init(size_t blockSize, const Sample* ir, size_t irLen)
{
  reset();

  if (blockSize == 0)
  {
    return false;
  }

  // Ignore zeros at the end of the impulse response because they only waste computation time
  while (irLen > 0 && ::fabs(ir[irLen-1]) < 0.000001f)
  {
    --irLen;
  }

  if (irLen == 0)
  {
    return true;
  }

  _blockSize = NextPowerOf2(blockSize);
  _segSize = 2 * _blockSize;
  _segCount = static_cast<size_t>(::ceil(static_cast<float>(irLen) / static_cast<float>(_blockSize)));
  _fftComplexSize = audiofft::AudioFFT::ComplexSize(_segSize);

  // FFT
  _fft.init(_segSize);
  _fftBuffer.resize(_segSize);

  // Prepare segments
  for (size_t i=0; i<_segCount; ++i)
  {
    _segments.push_back(new SplitComplex(_fftComplexSize));
  }

  // Prepare IR
  for (size_t i=0; i<_segCount; ++i)
  {
    SplitComplex* segment = new SplitComplex(_fftComplexSize);
    const size_t remaining = irLen - (i * _blockSize);
    const size_t sizeCopy = (remaining >= _blockSize) ? _blockSize : remaining;
    CopyAndPad(_fftBuffer, &ir[i*_blockSize], sizeCopy);
    _fft.fft(_fftBuffer.data(), segment->re(), segment->im());
    _segmentsIR.push_back(segment);
  }
  // Nenhum espectro de entrada foi calculado ainda: todos valem silencio.
  _segmentGeneration.assign(_segCount, 0u);
  _generation = 1;

  // Prepare convolution buffers
  _preMultiplied.resize(_fftComplexSize);
  _conv.resize(_fftComplexSize);
  _overlap.resize(_blockSize);

  // Prepare input buffer
  _inputBuffer.resize(_blockSize);
  _inputBufferFill = 0;

  // Reset current position
  _current = 0;

  return true;
}


void FFTConvolver::process(const Sample* input, Sample* output, size_t len)
{
  if (_segCount == 0)
  {
    ::memset(output, 0, len * sizeof(Sample));
    return;
  }

  size_t processed = 0;
  while (processed < len)
  {
    const bool inputBufferWasEmpty = (_inputBufferFill == 0);
    const size_t processing = std::min(len-processed, _blockSize-_inputBufferFill);
    const size_t inputBufferPos = _inputBufferFill;
    ::memcpy(_inputBuffer.data()+inputBufferPos, input+processed, processing * sizeof(Sample));

    // Forward FFT
    CopyAndPad(_fftBuffer, &_inputBuffer[0], _blockSize);
    _fft.fft(_fftBuffer.data(), _segments[_current]->re(), _segments[_current]->im());
    _segmentGeneration[_current] = _generation;

    // Complex multiplication
    if (inputBufferWasEmpty)
    {
      _preMultiplied.setZero();
      for (size_t i=1; i<_segCount; ++i)
      {
        const size_t indexIr = i;
        const size_t indexAudio = (_current + i) % _segCount;
        // Espectro de antes do ultimo clearHistory(): silencio, nada a somar.
        if (_segmentGeneration[indexAudio] != _generation) continue;
        ComplexMultiplyAccumulate(_preMultiplied, *_segmentsIR[indexIr], *_segments[indexAudio]);
      }
    }
    _conv.copyFrom(_preMultiplied);
    ComplexMultiplyAccumulate(_conv, *_segments[_current], *_segmentsIR[0]);

    // Backward FFT
    _fft.ifft(_fftBuffer.data(), _conv.re(), _conv.im());

    // Add overlap
    Sum(output+processed, _fftBuffer.data()+inputBufferPos, _overlap.data()+inputBufferPos, processing);

    // Input buffer full => Next block
    _inputBufferFill += processing;
    if (_inputBufferFill == _blockSize)
    {
      // Input buffer is empty again now
      _inputBuffer.setZero();
      _inputBufferFill = 0;

      // Save the overlap
      ::memcpy(_overlap.data(), _fftBuffer.data()+_blockSize, _blockSize * sizeof(Sample));

      // Update current segment
      _current = (_current > 0) ? (_current - 1) : (_segCount - 1);
    }

    processed += processing;
  }
}


size_t FFTConvolver::stepCount() const
{
  // Uma FFT da entrada, N-1 segmentos do IR (um por passo) e, por ultimo, a
  // IFFT com a saida.
  return _segCount > 0 ? _segCount + 1 : 0;
}


void FFTConvolver::beginSteppedBlock(const Sample* input, size_t fftAfterSteps)
{
  if (_segCount == 0)
  {
    return;
  }
  assert(_inputBufferFill == 0);
  ::memcpy(_inputBuffer.data(), input, _blockSize * sizeof(Sample));
  _preMultiplied.setZero();
  _steppedPending = true;
  _stepNext = 0;
  _stepFftPosition = std::min(fftAfterSteps, _segCount - 1);
}


bool FFTConvolver::advanceSteppedBlock(size_t steps, Sample* output)
{
  // Mesmas operacoes que process() faz com um bloco inteiro e o buffer de
  // entrada vazio, com os segmentos somados na mesma ordem (1..N-1): o
  // resultado e identico bit a bit. So a FFT pode vir no meio da soma, porque
  // nenhum segmento antigo depende dela.
  while (steps > 0 && _steppedPending)
  {
    if (_stepNext == _stepFftPosition)
    {
      CopyAndPad(_fftBuffer, &_inputBuffer[0], _blockSize);
      _fft.fft(_fftBuffer.data(), _segments[_current]->re(), _segments[_current]->im());
      _segmentGeneration[_current] = _generation;
    }
    else if (_stepNext < _segCount)
    {
      const size_t indexIr = _stepNext < _stepFftPosition ? _stepNext + 1 : _stepNext;
      const size_t indexAudio = (_current + indexIr) % _segCount;
      if (_segmentGeneration[indexAudio] == _generation)
      {
        ComplexMultiplyAccumulate(_preMultiplied, *_segmentsIR[indexIr], *_segments[indexAudio]);
      }
    }
    else
    {
      _conv.copyFrom(_preMultiplied);
      ComplexMultiplyAccumulate(_conv, *_segments[_current], *_segmentsIR[0]);
      _fft.ifft(_fftBuffer.data(), _conv.re(), _conv.im());
      Sum(output, _fftBuffer.data(), _overlap.data(), _blockSize);
      _inputBuffer.setZero();
      ::memcpy(_overlap.data(), _fftBuffer.data()+_blockSize, _blockSize * sizeof(Sample));
      _current = (_current > 0) ? (_current - 1) : (_segCount - 1);
      _steppedPending = false;
    }
    ++_stepNext;
    --steps;
  }
  return !_steppedPending;
}

} // End of namespace fftconvolver
